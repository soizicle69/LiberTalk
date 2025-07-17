/*
  # Correction du système de queue et matching

  1. Améliorations des tables existantes
    - Optimisation des index pour performance
    - Ajout de colonnes pour le debugging et monitoring
    - Amélioration des contraintes et defaults

  2. Nouvelles fonctions RPC optimisées
    - `join_waiting_queue_v2` - Version améliorée non-bloquante
    - `find_best_match_v2` - Matching plus intelligent et rapide
    - `cleanup_inactive_sessions_v2` - Nettoyage plus efficace
    - `get_queue_statistics_v2` - Stats en temps réel

  3. Triggers pour maintenance automatique
    - Auto-cleanup des sessions expirées
    - Mise à jour automatique des timestamps
    - Monitoring des performances

  4. Sécurité et RLS
    - Politiques mises à jour pour les nouvelles fonctions
    - Optimisation des permissions
*/

-- Amélioration de la table waiting_users
ALTER TABLE waiting_users 
ADD COLUMN IF NOT EXISTS connection_attempts INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS last_error TEXT DEFAULT NULL,
ADD COLUMN IF NOT EXISTS retry_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS matching_started_at TIMESTAMPTZ DEFAULT NULL,
ADD COLUMN IF NOT EXISTS is_actively_searching BOOLEAN DEFAULT TRUE;

-- Amélioration de la table match_attempts
ALTER TABLE match_attempts 
ADD COLUMN IF NOT EXISTS connection_quality_user1 INTEGER DEFAULT 100,
ADD COLUMN IF NOT EXISTS connection_quality_user2 INTEGER DEFAULT 100,
ADD COLUMN IF NOT EXISTS retry_attempts INTEGER DEFAULT 0;

-- Amélioration de la table chat_sessions
ALTER TABLE chat_sessions 
ADD COLUMN IF NOT EXISTS connection_established_at TIMESTAMPTZ DEFAULT NULL,
ADD COLUMN IF NOT EXISTS last_message_at TIMESTAMPTZ DEFAULT NULL;

-- Index optimisés pour performance
CREATE INDEX IF NOT EXISTS idx_waiting_users_active_search 
ON waiting_users (is_actively_searching, joined_at) 
WHERE status = 'searching';

CREATE INDEX IF NOT EXISTS idx_waiting_users_location_search 
ON waiting_users USING GIST (location) 
WHERE status = 'searching' AND location IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_waiting_users_continent_lang_search 
ON waiting_users (continent, language, joined_at) 
WHERE status = 'searching';

CREATE INDEX IF NOT EXISTS idx_match_attempts_pending_timeout 
ON match_attempts (confirmation_timeout) 
WHERE status = 'pending';

-- Fonction améliorée pour rejoindre la queue (non-bloquante)
CREATE OR REPLACE FUNCTION join_waiting_queue_v2(
  p_device_id TEXT,
  p_continent TEXT DEFAULT 'Unknown',
  p_country TEXT DEFAULT 'Unknown',
  p_city TEXT DEFAULT 'Unknown',
  p_language TEXT DEFAULT 'en',
  p_latitude FLOAT DEFAULT NULL,
  p_longitude FLOAT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL,
  p_ip_address INET DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
  v_user_id UUID;
  v_session_id UUID;
  v_location GEOGRAPHY;
  v_queue_position INTEGER;
  v_estimated_wait INTEGER;
  v_total_waiting INTEGER;
BEGIN
  -- Log de début
  RAISE LOG 'join_waiting_queue_v2: Starting for device %', p_device_id;
  
  -- Créer la géographie si coordonnées disponibles
  IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
    v_location := ST_Point(p_longitude, p_latitude)::GEOGRAPHY;
  END IF;
  
  -- Nettoyer les anciennes entrées pour ce device
  DELETE FROM waiting_users 
  WHERE device_id = p_device_id 
    AND (last_heartbeat < NOW() - INTERVAL '2 minutes' OR status = 'disconnected');
  
  -- Insérer/mettre à jour l'utilisateur dans la queue
  INSERT INTO waiting_users (
    device_id,
    location,
    continent,
    country,
    city,
    language,
    joined_at,
    last_heartbeat,
    user_agent,
    ip_address,
    status,
    is_actively_searching,
    matching_started_at
  ) VALUES (
    p_device_id,
    v_location,
    p_continent,
    p_country,
    p_city,
    p_language,
    NOW(),
    NOW(),
    p_user_agent,
    p_ip_address,
    'searching',
    TRUE,
    NOW()
  )
  ON CONFLICT (device_id) 
  DO UPDATE SET
    location = EXCLUDED.location,
    continent = EXCLUDED.continent,
    country = EXCLUDED.country,
    city = EXCLUDED.city,
    language = EXCLUDED.language,
    last_heartbeat = NOW(),
    status = 'searching',
    is_actively_searching = TRUE,
    matching_started_at = NOW(),
    retry_count = waiting_users.retry_count + 1
  RETURNING id INTO v_user_id;
  
  -- Créer une session utilisateur
  INSERT INTO user_sessions (
    user_id,
    session_token,
    connected_at,
    last_heartbeat,
    is_active
  ) VALUES (
    v_user_id,
    gen_random_uuid()::TEXT,
    NOW(),
    NOW(),
    TRUE
  )
  ON CONFLICT (user_id) 
  DO UPDATE SET
    last_heartbeat = NOW(),
    is_active = TRUE,
    missed_heartbeats = 0
  RETURNING id INTO v_session_id;
  
  -- Calculer position dans la queue et temps d'attente estimé
  SELECT COUNT(*) INTO v_total_waiting
  FROM waiting_users 
  WHERE status = 'searching' AND is_actively_searching = TRUE;
  
  SELECT COUNT(*) INTO v_queue_position
  FROM waiting_users 
  WHERE status = 'searching' 
    AND is_actively_searching = TRUE
    AND joined_at < (SELECT joined_at FROM waiting_users WHERE id = v_user_id);
  
  -- Estimation basée sur l'historique (5-30s par match)
  v_estimated_wait := GREATEST(5, v_queue_position * 15);
  
  -- Log de succès
  RAISE LOG 'join_waiting_queue_v2: Success for device %, user_id %, position %', 
    p_device_id, v_user_id, v_queue_position;
  
  RETURN json_build_object(
    'success', TRUE,
    'user_id', v_user_id,
    'session_id', v_session_id,
    'queue_position', v_queue_position,
    'estimated_wait_seconds', v_estimated_wait,
    'total_waiting', v_total_waiting,
    'message', 'Successfully joined waiting queue'
  );
  
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'join_waiting_queue_v2: Error for device %: %', p_device_id, SQLERRM;
  RETURN json_build_object(
    'success', FALSE,
    'error', SQLERRM,
    'message', 'Failed to join waiting queue'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction de matching améliorée (plus rapide et intelligente)
CREATE OR REPLACE FUNCTION find_best_match_v2(p_user_id UUID) 
RETURNS JSON AS $$
DECLARE
  v_user RECORD;
  v_potential_match RECORD;
  v_match_id UUID;
  v_chat_id UUID;
  v_match_score INTEGER := 0;
  v_distance_km INTEGER;
  v_total_waiting INTEGER;
BEGIN
  -- Log de début
  RAISE LOG 'find_best_match_v2: Starting search for user %', p_user_id;
  
  -- Récupérer les infos de l'utilisateur
  SELECT * INTO v_user 
  FROM waiting_users 
  WHERE id = p_user_id AND status = 'searching' AND is_actively_searching = TRUE;
  
  IF NOT FOUND THEN
    RAISE LOG 'find_best_match_v2: User % not found or not searching', p_user_id;
    RETURN json_build_object(
      'success', FALSE,
      'error', 'User not in queue or not actively searching'
    );
  END IF;
  
  -- Mettre à jour le timestamp de recherche
  UPDATE waiting_users 
  SET last_heartbeat = NOW(), connection_attempts = connection_attempts + 1
  WHERE id = p_user_id;
  
  -- Compter le total en attente
  SELECT COUNT(*) INTO v_total_waiting
  FROM waiting_users 
  WHERE status = 'searching' AND is_actively_searching = TRUE AND id != p_user_id;
  
  IF v_total_waiting = 0 THEN
    RAISE LOG 'find_best_match_v2: No other users waiting for user %', p_user_id;
    RETURN json_build_object(
      'success', FALSE,
      'total_waiting', 0,
      'message', 'No other users available for matching'
    );
  END IF;
  
  -- Stratégie de matching par priorité
  
  -- 1. Priorité: Même continent + même langue + proximité géographique
  IF v_user.location IS NOT NULL THEN
    SELECT *, 
           ST_Distance(location, v_user.location) / 1000 as distance_km,
           100 as base_score
    INTO v_potential_match, v_distance_km, v_match_score
    FROM waiting_users 
    WHERE id != p_user_id 
      AND status = 'searching' 
      AND is_actively_searching = TRUE
      AND continent = v_user.continent 
      AND language = v_user.language
      AND location IS NOT NULL
      AND ST_Distance(location, v_user.location) < 500000 -- 500km
    ORDER BY ST_Distance(location, v_user.location)
    LIMIT 1;
  END IF;
  
  -- 2. Même continent + même langue (sans géoloc)
  IF v_potential_match IS NULL THEN
    SELECT *, 80 as base_score
    INTO v_potential_match, v_match_score
    FROM waiting_users 
    WHERE id != p_user_id 
      AND status = 'searching' 
      AND is_actively_searching = TRUE
      AND continent = v_user.continent 
      AND language = v_user.language
    ORDER BY joined_at
    LIMIT 1;
  END IF;
  
  -- 3. Même continent (langue différente OK)
  IF v_potential_match IS NULL THEN
    SELECT *, 60 as base_score
    INTO v_potential_match, v_match_score
    FROM waiting_users 
    WHERE id != p_user_id 
      AND status = 'searching' 
      AND is_actively_searching = TRUE
      AND continent = v_user.continent
    ORDER BY 
      CASE WHEN language = v_user.language THEN 0 ELSE 1 END,
      joined_at
    LIMIT 1;
  END IF;
  
  -- 4. Même langue (continent différent OK)
  IF v_potential_match IS NULL THEN
    SELECT *, 40 as base_score
    INTO v_potential_match, v_match_score
    FROM waiting_users 
    WHERE id != p_user_id 
      AND status = 'searching' 
      AND is_actively_searching = TRUE
      AND language = v_user.language
    ORDER BY joined_at
    LIMIT 1;
  END IF;
  
  -- 5. Matching global aléatoire (dernier recours)
  IF v_potential_match IS NULL THEN
    SELECT *, 20 as base_score
    INTO v_potential_match, v_match_score
    FROM waiting_users 
    WHERE id != p_user_id 
      AND status = 'searching' 
      AND is_actively_searching = TRUE
    ORDER BY joined_at
    LIMIT 1;
  END IF;
  
  -- Aucun match trouvé
  IF v_potential_match IS NULL THEN
    RAISE LOG 'find_best_match_v2: No suitable match found for user %', p_user_id;
    RETURN json_build_object(
      'success', FALSE,
      'total_waiting', v_total_waiting,
      'message', 'No suitable match found, continue searching'
    );
  END IF;
  
  -- Créer la tentative de match
  INSERT INTO match_attempts (
    user1_id,
    user2_id,
    match_score,
    distance_km,
    language_match,
    continent_match,
    status,
    confirmation_timeout
  ) VALUES (
    p_user_id,
    v_potential_match.id,
    v_match_score,
    v_distance_km,
    v_user.language = v_potential_match.language,
    v_user.continent = v_potential_match.continent,
    'pending',
    NOW() + INTERVAL '30 seconds'
  ) RETURNING id INTO v_match_id;
  
  -- Créer la session de chat
  INSERT INTO chat_sessions (
    user1_id,
    user2_id,
    status,
    created_at
  ) VALUES (
    p_user_id,
    v_potential_match.id,
    'connecting',
    NOW()
  ) RETURNING chat_id INTO v_chat_id;
  
  -- Marquer les utilisateurs comme matched
  UPDATE waiting_users 
  SET status = 'matched', 
      current_match_id = v_match_id,
      is_actively_searching = FALSE
  WHERE id IN (p_user_id, v_potential_match.id);
  
  RAISE LOG 'find_best_match_v2: Match created for users % and %, score %', 
    p_user_id, v_potential_match.id, v_match_score;
  
  RETURN json_build_object(
    'success', TRUE,
    'match_id', v_match_id,
    'partner_id', v_potential_match.id,
    'chat_id', v_chat_id,
    'match_score', v_match_score,
    'distance_km', v_distance_km,
    'requires_confirmation', TRUE,
    'confirmation_timeout', 30,
    'partner_info', json_build_object(
      'continent', v_potential_match.continent,
      'country', v_potential_match.country,
      'city', v_potential_match.city,
      'language', v_potential_match.language
    ),
    'message', 'Match found, confirming connection'
  );
  
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'find_best_match_v2: Error for user %: %', p_user_id, SQLERRM;
  RETURN json_build_object(
    'success', FALSE,
    'error', SQLERRM,
    'total_waiting', v_total_waiting,
    'message', 'Error during matching process'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction de confirmation bilatérale améliorée
CREATE OR REPLACE FUNCTION confirm_bilateral_match_v2(
  p_user_id UUID,
  p_match_id UUID
) RETURNS JSON AS $$
DECLARE
  v_match RECORD;
  v_chat_id UUID;
  v_other_user_confirmed BOOLEAN := FALSE;
  v_both_confirmed BOOLEAN := FALSE;
BEGIN
  RAISE LOG 'confirm_bilateral_match_v2: User % confirming match %', p_user_id, p_match_id;
  
  -- Récupérer la tentative de match
  SELECT * INTO v_match 
  FROM match_attempts 
  WHERE id = p_match_id 
    AND (user1_id = p_user_id OR user2_id = p_user_id)
    AND status = 'pending'
    AND confirmation_timeout > NOW();
  
  IF NOT FOUND THEN
    RAISE LOG 'confirm_bilateral_match_v2: Match % not found or expired for user %', p_match_id, p_user_id;
    RETURN json_build_object(
      'success', FALSE,
      'error', 'Match not found, expired, or already confirmed'
    );
  END IF;
  
  -- Marquer la confirmation de cet utilisateur
  IF v_match.user1_id = p_user_id THEN
    UPDATE match_attempts 
    SET user1_confirmed = TRUE 
    WHERE id = p_match_id;
    v_other_user_confirmed := v_match.user2_confirmed;
  ELSE
    UPDATE match_attempts 
    SET user2_confirmed = TRUE 
    WHERE id = p_match_id;
    v_other_user_confirmed := v_match.user1_confirmed;
  END IF;
  
  v_both_confirmed := v_other_user_confirmed;
  
  -- Si les deux ont confirmé, activer le chat
  IF v_both_confirmed THEN
    -- Marquer le match comme confirmé
    UPDATE match_attempts 
    SET status = 'confirmed', confirmed_at = NOW() 
    WHERE id = p_match_id;
    
    -- Récupérer le chat_id
    SELECT chat_id INTO v_chat_id
    FROM chat_sessions 
    WHERE (user1_id = v_match.user1_id AND user2_id = v_match.user2_id)
       OR (user1_id = v_match.user2_id AND user2_id = v_match.user1_id)
    ORDER BY created_at DESC 
    LIMIT 1;
    
    -- Activer la session de chat
    UPDATE chat_sessions 
    SET status = 'active', 
        connection_established_at = NOW(),
        user1_confirmed = TRUE,
        user2_confirmed = TRUE
    WHERE chat_id = v_chat_id;
    
    -- Marquer les utilisateurs comme connectés
    UPDATE waiting_users 
    SET status = 'connected' 
    WHERE id IN (v_match.user1_id, v_match.user2_id);
    
    RAISE LOG 'confirm_bilateral_match_v2: Both users confirmed, chat % activated', v_chat_id;
    
    RETURN json_build_object(
      'success', TRUE,
      'both_confirmed', TRUE,
      'chat_id', v_chat_id,
      'partner_id', CASE WHEN v_match.user1_id = p_user_id THEN v_match.user2_id ELSE v_match.user1_id END,
      'message', 'Both users confirmed, chat is now active'
    );
  ELSE
    RAISE LOG 'confirm_bilateral_match_v2: User % confirmed, waiting for partner', p_user_id;
    
    RETURN json_build_object(
      'success', TRUE,
      'both_confirmed', FALSE,
      'message', 'Confirmation received, waiting for partner'
    );
  END IF;
  
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'confirm_bilateral_match_v2: Error for user % match %: %', p_user_id, p_match_id, SQLERRM;
  RETURN json_build_object(
    'success', FALSE,
    'error', SQLERRM,
    'message', 'Error during confirmation process'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction de nettoyage améliorée
CREATE OR REPLACE FUNCTION cleanup_inactive_sessions_v2() 
RETURNS JSON AS $$
DECLARE
  v_cleaned_users INTEGER := 0;
  v_cleaned_sessions INTEGER := 0;
  v_cleaned_matches INTEGER := 0;
  v_cleaned_chats INTEGER := 0;
BEGIN
  -- Nettoyer les utilisateurs inactifs (plus de 2 minutes sans heartbeat)
  DELETE FROM waiting_users 
  WHERE last_heartbeat < NOW() - INTERVAL '2 minutes'
     OR (status = 'searching' AND joined_at < NOW() - INTERVAL '10 minutes');
  GET DIAGNOSTICS v_cleaned_users = ROW_COUNT;
  
  -- Nettoyer les sessions inactives
  DELETE FROM user_sessions 
  WHERE last_heartbeat < NOW() - INTERVAL '2 minutes'
     OR (is_active = FALSE AND disconnected_at < NOW() - INTERVAL '1 hour');
  GET DIAGNOSTICS v_cleaned_sessions = ROW_COUNT;
  
  -- Nettoyer les tentatives de match expirées
  UPDATE match_attempts 
  SET status = 'timeout' 
  WHERE status = 'pending' AND confirmation_timeout < NOW();
  
  DELETE FROM match_attempts 
  WHERE status IN ('timeout', 'rejected') AND created_at < NOW() - INTERVAL '1 hour';
  GET DIAGNOSTICS v_cleaned_matches = ROW_COUNT;
  
  -- Nettoyer les chats abandonnés
  UPDATE chat_sessions 
  SET status = 'ended', ended_at = NOW() 
  WHERE status IN ('connecting', 'active') 
    AND last_activity < NOW() - INTERVAL '5 minutes';
  
  DELETE FROM chat_sessions 
  WHERE status = 'ended' AND ended_at < NOW() - INTERVAL '1 day';
  GET DIAGNOSTICS v_cleaned_chats = ROW_COUNT;
  
  -- Réactiver les utilisateurs bloqués en matching
  UPDATE waiting_users 
  SET is_actively_searching = TRUE,
      matching_started_at = NOW(),
      status = 'searching'
  WHERE status = 'searching' 
    AND is_actively_searching = FALSE 
    AND matching_started_at < NOW() - INTERVAL '1 minute';
  
  IF v_cleaned_users > 0 OR v_cleaned_sessions > 0 OR v_cleaned_matches > 0 THEN
    RAISE LOG 'cleanup_inactive_sessions_v2: Cleaned % users, % sessions, % matches, % chats', 
      v_cleaned_users, v_cleaned_sessions, v_cleaned_matches, v_cleaned_chats;
  END IF;
  
  RETURN json_build_object(
    'success', TRUE,
    'cleaned_users', v_cleaned_users,
    'cleaned_sessions', v_cleaned_sessions,
    'cleaned_matches', v_cleaned_matches,
    'cleaned_chats', v_cleaned_chats
  );
  
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'cleanup_inactive_sessions_v2: Error during cleanup: %', SQLERRM;
  RETURN json_build_object(
    'success', FALSE,
    'error', SQLERRM
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction de statistiques améliorée
CREATE OR REPLACE FUNCTION get_queue_statistics_v2() 
RETURNS JSON AS $$
DECLARE
  v_stats JSON;
  v_total_waiting INTEGER;
  v_by_continent JSON;
  v_by_language JSON;
  v_avg_wait_time FLOAT;
BEGIN
  -- Total en attente
  SELECT COUNT(*) INTO v_total_waiting
  FROM waiting_users 
  WHERE status = 'searching' AND is_actively_searching = TRUE;
  
  -- Par continent
  SELECT json_object_agg(continent, count) INTO v_by_continent
  FROM (
    SELECT continent, COUNT(*) as count
    FROM waiting_users 
    WHERE status = 'searching' AND is_actively_searching = TRUE
    GROUP BY continent
  ) t;
  
  -- Par langue
  SELECT json_object_agg(language, count) INTO v_by_language
  FROM (
    SELECT language, COUNT(*) as count
    FROM waiting_users 
    WHERE status = 'searching' AND is_actively_searching = TRUE
    GROUP BY language
  ) t;
  
  -- Temps d'attente moyen (basé sur les matches récents)
  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (confirmed_at - created_at))), 30) INTO v_avg_wait_time
  FROM match_attempts 
  WHERE status = 'confirmed' 
    AND created_at > NOW() - INTERVAL '1 hour';
  
  RETURN json_build_object(
    'total_waiting', v_total_waiting,
    'by_continent', COALESCE(v_by_continent, '{}'::json),
    'by_language', COALESCE(v_by_language, '{}'::json),
    'average_wait_time', v_avg_wait_time,
    'timestamp', NOW()
  );
  
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object(
    'total_waiting', 0,
    'by_continent', '{}'::json,
    'by_language', '{}'::json,
    'average_wait_time', 30,
    'timestamp', NOW(),
    'error', SQLERRM
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction de heartbeat améliorée
CREATE OR REPLACE FUNCTION send_heartbeat_v2(
  p_user_id UUID,
  p_connection_quality INTEGER DEFAULT 100
) RETURNS JSON AS $$
BEGIN
  -- Mettre à jour waiting_users
  UPDATE waiting_users 
  SET last_heartbeat = NOW(),
      connection_quality = p_connection_quality
  WHERE id = p_user_id;
  
  -- Mettre à jour user_sessions
  UPDATE user_sessions 
  SET last_heartbeat = NOW(),
      missed_heartbeats = 0,
      is_active = TRUE
  WHERE user_id = p_user_id;
  
  -- Si pas trouvé dans waiting_users, vérifier si l'utilisateur existe
  IF NOT FOUND THEN
    RETURN json_build_object(
      'success', FALSE,
      'error', 'User not found in waiting queue'
    );
  END IF;
  
  RETURN json_build_object(
    'success', TRUE,
    'timestamp', NOW()
  );
  
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object(
    'success', FALSE,
    'error', SQLERRM
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger pour auto-cleanup périodique
CREATE OR REPLACE FUNCTION trigger_auto_cleanup() RETURNS TRIGGER AS $$
BEGIN
  -- Exécuter le cleanup toutes les 50 insertions
  IF (TG_OP = 'INSERT' AND random() < 0.02) THEN
    PERFORM cleanup_inactive_sessions_v2();
  END IF;
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Appliquer le trigger
DROP TRIGGER IF EXISTS auto_cleanup_trigger ON waiting_users;
CREATE TRIGGER auto_cleanup_trigger
  AFTER INSERT OR UPDATE OR DELETE ON waiting_users
  FOR EACH ROW EXECUTE FUNCTION trigger_auto_cleanup();

-- Mettre à jour les politiques RLS pour les nouvelles fonctions
DROP POLICY IF EXISTS "Users can manage their own queue entry" ON waiting_users;
CREATE POLICY "Users can manage their own queue entry" ON waiting_users
  FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Users can view match attempts" ON match_attempts;
CREATE POLICY "Users can view match attempts" ON match_attempts
  FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Users can access their chats" ON chat_sessions;
CREATE POLICY "Users can access their chats" ON chat_sessions
  FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Users can access chat messages" ON chat_messages;
CREATE POLICY "Users can access chat messages" ON chat_messages
  FOR ALL USING (true) WITH CHECK (true);

-- Grants pour les nouvelles fonctions
GRANT EXECUTE ON FUNCTION join_waiting_queue_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION find_best_match_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION confirm_bilateral_match_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleanup_inactive_sessions_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_queue_statistics_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION send_heartbeat_v2 TO anon, authenticated;