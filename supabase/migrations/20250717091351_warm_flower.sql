/*
  # Correction du système de queue et matching - Version corrigée

  1. Nouvelles fonctions RPC optimisées
    - `join_waiting_queue_v2` : Ajout non-bloquant à la queue
    - `find_best_match_v2` : Matching intelligent par priorité
    - `confirm_bilateral_match_v2` : Confirmation bilatérale
    - `cleanup_inactive_sessions_v2` : Nettoyage automatique
    - `get_queue_statistics_v2` : Statistiques temps réel
    - `send_heartbeat_v2` : Heartbeat avec qualité connexion

  2. Nouvelles colonnes pour monitoring
    - Tentatives de connexion et erreurs
    - Qualité de connexion
    - Timestamps de recherche

  3. Index optimisés pour performance
    - Recherche géographique GIST
    - Recherche par continent/langue
    - Recherche active uniquement

  4. Auto-cleanup avec triggers
*/

-- Ajouter nouvelles colonnes à waiting_users
DO $$
BEGIN
  -- Colonnes pour monitoring et debugging
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'waiting_users' AND column_name = 'connection_attempts') THEN
    ALTER TABLE waiting_users ADD COLUMN connection_attempts INTEGER DEFAULT 0;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'waiting_users' AND column_name = 'last_error') THEN
    ALTER TABLE waiting_users ADD COLUMN last_error TEXT DEFAULT NULL;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'waiting_users' AND column_name = 'retry_count') THEN
    ALTER TABLE waiting_users ADD COLUMN retry_count INTEGER DEFAULT 0;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'waiting_users' AND column_name = 'matching_started_at') THEN
    ALTER TABLE waiting_users ADD COLUMN matching_started_at TIMESTAMPTZ DEFAULT NULL;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'waiting_users' AND column_name = 'is_actively_searching') THEN
    ALTER TABLE waiting_users ADD COLUMN is_actively_searching BOOLEAN DEFAULT TRUE;
  END IF;
END $$;

-- Ajouter nouvelles colonnes à match_attempts
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'match_attempts' AND column_name = 'connection_quality_user1') THEN
    ALTER TABLE match_attempts ADD COLUMN connection_quality_user1 INTEGER DEFAULT 100;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'match_attempts' AND column_name = 'connection_quality_user2') THEN
    ALTER TABLE match_attempts ADD COLUMN connection_quality_user2 INTEGER DEFAULT 100;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'match_attempts' AND column_name = 'retry_attempts') THEN
    ALTER TABLE match_attempts ADD COLUMN retry_attempts INTEGER DEFAULT 0;
  END IF;
END $$;

-- Créer index optimisés
CREATE INDEX IF NOT EXISTS idx_waiting_users_active_search 
ON waiting_users (status, is_actively_searching, joined_at) 
WHERE status = 'searching' AND is_actively_searching = TRUE;

CREATE INDEX IF NOT EXISTS idx_waiting_users_location_search 
ON waiting_users USING GIST (location) 
WHERE status = 'searching' AND location IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_waiting_users_continent_lang_search 
ON waiting_users (continent, language, joined_at) 
WHERE status = 'searching';

-- Fonction pour rejoindre la queue (version non-bloquante)
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
  v_queue_position INTEGER;
  v_estimated_wait INTEGER;
  v_location GEOGRAPHY(POINT, 4326);
BEGIN
  -- Log début de fonction
  RAISE LOG 'join_waiting_queue_v2: Starting for device %', p_device_id;
  
  -- Créer point géographique si coordonnées disponibles
  IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::GEOGRAPHY;
  END IF;
  
  -- Nettoyer les anciennes entrées pour ce device
  DELETE FROM waiting_users WHERE device_id = p_device_id;
  
  -- Insérer nouvel utilisateur dans la queue
  INSERT INTO waiting_users (
    device_id,
    location,
    continent,
    country,
    city,
    language,
    status,
    joined_at,
    last_heartbeat,
    user_agent,
    ip_address,
    is_actively_searching,
    matching_started_at
  ) VALUES (
    p_device_id,
    v_location,
    p_continent,
    p_country,
    p_city,
    p_language,
    'searching',
    NOW(),
    NOW(),
    p_user_agent,
    p_ip_address,
    TRUE,
    NOW()
  ) RETURNING id INTO v_user_id;
  
  -- Créer session utilisateur
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
  ) RETURNING id INTO v_session_id;
  
  -- Calculer position dans la queue
  SELECT COUNT(*) INTO v_queue_position
  FROM waiting_users 
  WHERE status = 'searching' 
    AND joined_at < (SELECT joined_at FROM waiting_users WHERE id = v_user_id);
  
  -- Estimer temps d'attente (5s par personne devant)
  v_estimated_wait := v_queue_position * 5;
  
  RAISE LOG 'join_waiting_queue_v2: Success for device %, user_id %, position %', 
    p_device_id, v_user_id, v_queue_position;
  
  RETURN json_build_object(
    'success', TRUE,
    'user_id', v_user_id,
    'session_id', v_session_id,
    'queue_position', v_queue_position,
    'estimated_wait_seconds', v_estimated_wait,
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

-- Fonction de matching intelligent (version corrigée)
CREATE OR REPLACE FUNCTION find_best_match_v2(p_user_id UUID) 
RETURNS JSON AS $$
DECLARE
  v_current_user RECORD;
  v_potential_match RECORD;
  v_distance_km INTEGER;
  v_match_score INTEGER;
  v_match_id UUID;
  v_chat_id UUID;
  v_total_waiting INTEGER;
BEGIN
  -- Log début de recherche
  RAISE LOG 'find_best_match_v2: Starting search for user %', p_user_id;
  
  -- Récupérer infos utilisateur courant
  SELECT * INTO v_current_user 
  FROM waiting_users 
  WHERE id = p_user_id AND status = 'searching';
  
  IF NOT FOUND THEN
    RAISE LOG 'find_best_match_v2: User % not found or not searching', p_user_id;
    RETURN json_build_object(
      'success', FALSE,
      'error', 'User not found or not in searching state'
    );
  END IF;
  
  -- Marquer comme activement en recherche
  UPDATE waiting_users 
  SET matching_started_at = NOW(), 
      is_actively_searching = TRUE,
      connection_attempts = connection_attempts + 1
  WHERE id = p_user_id;
  
  -- Compter total en attente
  SELECT COUNT(*) INTO v_total_waiting
  FROM waiting_users 
  WHERE status = 'searching' AND id != p_user_id;
  
  IF v_total_waiting = 0 THEN
    RAISE LOG 'find_best_match_v2: No other users waiting for user %', p_user_id;
    RETURN json_build_object(
      'success', FALSE,
      'message', 'No other users available',
      'total_waiting', 0
    );
  END IF;
  
  -- Stratégie de matching par priorité
  
  -- Priorité 1: Même continent + langue + proximité (<500km)
  IF v_current_user.location IS NOT NULL THEN
    SELECT u.*, 
           ROUND(ST_Distance(v_current_user.location, u.location) / 1000)::INTEGER,
           90 + CASE WHEN u.language = v_current_user.language THEN 10 ELSE 0 END
    INTO v_potential_match, v_distance_km, v_match_score
    FROM waiting_users u
    WHERE u.id != p_user_id 
      AND u.status = 'searching'
      AND u.continent = v_current_user.continent
      AND u.language = v_current_user.language
      AND u.location IS NOT NULL
      AND ST_Distance(v_current_user.location, u.location) <= 500000
    ORDER BY ST_Distance(v_current_user.location, u.location), u.joined_at
    LIMIT 1;
    
    IF FOUND THEN
      RAISE LOG 'find_best_match_v2: Priority 1 match found (nearby + same continent/language)';
    END IF;
  END IF;
  
  -- Priorité 2: Même continent + langue
  IF NOT FOUND THEN
    SELECT u.*, 
           CASE WHEN v_current_user.location IS NOT NULL AND u.location IS NOT NULL 
                THEN ROUND(ST_Distance(v_current_user.location, u.location) / 1000)::INTEGER 
                ELSE NULL END,
           80
    INTO v_potential_match, v_distance_km, v_match_score
    FROM waiting_users u
    WHERE u.id != p_user_id 
      AND u.status = 'searching'
      AND u.continent = v_current_user.continent
      AND u.language = v_current_user.language
    ORDER BY u.joined_at
    LIMIT 1;
    
    IF FOUND THEN
      RAISE LOG 'find_best_match_v2: Priority 2 match found (same continent/language)';
    END IF;
  END IF;
  
  -- Priorité 3: Même continent
  IF NOT FOUND THEN
    SELECT u.*, 
           CASE WHEN v_current_user.location IS NOT NULL AND u.location IS NOT NULL 
                THEN ROUND(ST_Distance(v_current_user.location, u.location) / 1000)::INTEGER 
                ELSE NULL END,
           60
    INTO v_potential_match, v_distance_km, v_match_score
    FROM waiting_users u
    WHERE u.id != p_user_id 
      AND u.status = 'searching'
      AND u.continent = v_current_user.continent
    ORDER BY u.joined_at
    LIMIT 1;
    
    IF FOUND THEN
      RAISE LOG 'find_best_match_v2: Priority 3 match found (same continent)';
    END IF;
  END IF;
  
  -- Priorité 4: Même langue
  IF NOT FOUND THEN
    SELECT u.*, 
           CASE WHEN v_current_user.location IS NOT NULL AND u.location IS NOT NULL 
                THEN ROUND(ST_Distance(v_current_user.location, u.location) / 1000)::INTEGER 
                ELSE NULL END,
           50
    INTO v_potential_match, v_distance_km, v_match_score
    FROM waiting_users u
    WHERE u.id != p_user_id 
      AND u.status = 'searching'
      AND u.language = v_current_user.language
    ORDER BY u.joined_at
    LIMIT 1;
    
    IF FOUND THEN
      RAISE LOG 'find_best_match_v2: Priority 4 match found (same language)';
    END IF;
  END IF;
  
  -- Priorité 5: Matching global aléatoire
  IF NOT FOUND THEN
    SELECT u.*, 
           CASE WHEN v_current_user.location IS NOT NULL AND u.location IS NOT NULL 
                THEN ROUND(ST_Distance(v_current_user.location, u.location) / 1000)::INTEGER 
                ELSE NULL END,
           30
    INTO v_potential_match, v_distance_km, v_match_score
    FROM waiting_users u
    WHERE u.id != p_user_id 
      AND u.status = 'searching'
    ORDER BY RANDOM()
    LIMIT 1;
    
    IF FOUND THEN
      RAISE LOG 'find_best_match_v2: Priority 5 match found (global random)';
    END IF;
  END IF;
  
  -- Aucun match trouvé
  IF NOT FOUND THEN
    RAISE LOG 'find_best_match_v2: No match found for user %', p_user_id;
    RETURN json_build_object(
      'success', FALSE,
      'message', 'No suitable match found',
      'total_waiting', v_total_waiting
    );
  END IF;
  
  -- Créer tentative de match
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
    v_current_user.language = v_potential_match.language,
    v_current_user.continent = v_potential_match.continent,
    'pending',
    NOW() + INTERVAL '30 seconds'
  ) RETURNING id INTO v_match_id;
  
  -- Créer session de chat
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
    'message', 'Match found, awaiting confirmation'
  );
  
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'find_best_match_v2: Error for user %: %', p_user_id, SQLERRM;
  RETURN json_build_object(
    'success', FALSE,
    'error', SQLERRM,
    'message', 'Error during matching process'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction de confirmation bilatérale
CREATE OR REPLACE FUNCTION confirm_bilateral_match_v2(
  p_user_id UUID,
  p_match_id UUID
) RETURNS JSON AS $$
DECLARE
  v_match RECORD;
  v_chat_id UUID;
  v_partner_id UUID;
  v_both_confirmed BOOLEAN := FALSE;
BEGIN
  RAISE LOG 'confirm_bilateral_match_v2: Starting confirmation for user % match %', p_user_id, p_match_id;
  
  -- Récupérer infos du match
  SELECT * INTO v_match 
  FROM match_attempts 
  WHERE id = p_match_id 
    AND (user1_id = p_user_id OR user2_id = p_user_id)
    AND status = 'pending';
  
  IF NOT FOUND THEN
    RETURN json_build_object(
      'success', FALSE,
      'error', 'Match not found or already processed'
    );
  END IF;
  
  -- Vérifier timeout
  IF v_match.confirmation_timeout < NOW() THEN
    UPDATE match_attempts SET status = 'timeout' WHERE id = p_match_id;
    RETURN json_build_object(
      'success', FALSE,
      'error', 'Match confirmation timeout'
    );
  END IF;
  
  -- Déterminer partner_id
  v_partner_id := CASE WHEN v_match.user1_id = p_user_id 
                       THEN v_match.user2_id 
                       ELSE v_match.user1_id END;
  
  -- Confirmer pour cet utilisateur
  IF v_match.user1_id = p_user_id THEN
    UPDATE match_attempts 
    SET user1_confirmed = TRUE, retry_attempts = retry_attempts + 1
    WHERE id = p_match_id;
  ELSE
    UPDATE match_attempts 
    SET user2_confirmed = TRUE, retry_attempts = retry_attempts + 1
    WHERE id = p_match_id;
  END IF;
  
  -- Vérifier si les deux ont confirmé
  SELECT user1_confirmed AND user2_confirmed INTO v_both_confirmed
  FROM match_attempts WHERE id = p_match_id;
  
  IF v_both_confirmed THEN
    -- Activer le chat
    UPDATE match_attempts 
    SET status = 'confirmed', confirmed_at = NOW() 
    WHERE id = p_match_id;
    
    -- Récupérer chat_id
    SELECT chat_id INTO v_chat_id
    FROM chat_sessions 
    WHERE (user1_id = p_user_id AND user2_id = v_partner_id)
       OR (user1_id = v_partner_id AND user2_id = p_user_id);
    
    -- Activer session de chat
    UPDATE chat_sessions 
    SET status = 'active', user1_confirmed = TRUE, user2_confirmed = TRUE
    WHERE chat_id = v_chat_id;
    
    -- Marquer utilisateurs comme connectés
    UPDATE waiting_users 
    SET status = 'connected' 
    WHERE id IN (p_user_id, v_partner_id);
    
    RAISE LOG 'confirm_bilateral_match_v2: Both users confirmed, chat % activated', v_chat_id;
    
    RETURN json_build_object(
      'success', TRUE,
      'both_confirmed', TRUE,
      'chat_id', v_chat_id,
      'partner_id', v_partner_id,
      'message', 'Match confirmed, chat is now active'
    );
  ELSE
    RAISE LOG 'confirm_bilateral_match_v2: Waiting for partner confirmation';
    RETURN json_build_object(
      'success', TRUE,
      'both_confirmed', FALSE,
      'partner_id', v_partner_id,
      'message', 'Waiting for partner confirmation'
    );
  END IF;
  
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'confirm_bilateral_match_v2: Error: %', SQLERRM;
  RETURN json_build_object(
    'success', FALSE,
    'error', SQLERRM
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction de nettoyage optimisée
CREATE OR REPLACE FUNCTION cleanup_inactive_sessions_v2() 
RETURNS JSON AS $$
DECLARE
  v_cleaned_users INTEGER := 0;
  v_cleaned_sessions INTEGER := 0;
  v_cleaned_matches INTEGER := 0;
BEGIN
  -- Nettoyer utilisateurs inactifs (>2 minutes sans heartbeat)
  DELETE FROM waiting_users 
  WHERE last_heartbeat < NOW() - INTERVAL '2 minutes';
  GET DIAGNOSTICS v_cleaned_users = ROW_COUNT;
  
  -- Nettoyer sessions inactives
  DELETE FROM user_sessions 
  WHERE last_heartbeat < NOW() - INTERVAL '2 minutes';
  GET DIAGNOSTICS v_cleaned_sessions = ROW_COUNT;
  
  -- Nettoyer matches expirés
  UPDATE match_attempts 
  SET status = 'timeout' 
  WHERE status = 'pending' AND confirmation_timeout < NOW();
  GET DIAGNOSTICS v_cleaned_matches = ROW_COUNT;
  
  -- Réactiver utilisateurs bloqués en recherche depuis >1 minute
  UPDATE waiting_users 
  SET is_actively_searching = TRUE,
      matching_started_at = NOW(),
      retry_count = retry_count + 1
  WHERE status = 'searching' 
    AND is_actively_searching = FALSE 
    AND matching_started_at < NOW() - INTERVAL '1 minute';
  
  IF v_cleaned_users > 0 OR v_cleaned_sessions > 0 OR v_cleaned_matches > 0 THEN
    RAISE LOG 'cleanup_inactive_sessions_v2: Cleaned % users, % sessions, % matches', 
      v_cleaned_users, v_cleaned_sessions, v_cleaned_matches;
  END IF;
  
  RETURN json_build_object(
    'success', TRUE,
    'cleaned_users', v_cleaned_users,
    'cleaned_sessions', v_cleaned_sessions,
    'cleaned_matches', v_cleaned_matches
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction de statistiques
CREATE OR REPLACE FUNCTION get_queue_statistics_v2() 
RETURNS JSON AS $$
DECLARE
  v_stats JSON;
BEGIN
  SELECT json_build_object(
    'total_waiting', COUNT(*),
    'by_continent', json_object_agg(continent, continent_count),
    'by_language', json_object_agg(language, language_count),
    'average_wait_time', COALESCE(AVG(EXTRACT(EPOCH FROM (NOW() - joined_at))), 0),
    'timestamp', NOW()
  ) INTO v_stats
  FROM (
    SELECT 
      continent,
      language,
      COUNT(*) OVER (PARTITION BY continent) as continent_count,
      COUNT(*) OVER (PARTITION BY language) as language_count,
      joined_at
    FROM waiting_users 
    WHERE status = 'searching'
  ) subq;
  
  RETURN COALESCE(v_stats, json_build_object(
    'total_waiting', 0,
    'by_continent', json_build_object(),
    'by_language', json_build_object(),
    'average_wait_time', 0,
    'timestamp', NOW()
  ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction heartbeat améliorée
CREATE OR REPLACE FUNCTION send_heartbeat_v2(
  p_user_id UUID,
  p_connection_quality INTEGER DEFAULT 100
) RETURNS JSON AS $$
BEGIN
  -- Mettre à jour heartbeat utilisateur
  UPDATE waiting_users 
  SET last_heartbeat = NOW(),
      connection_quality = p_connection_quality
  WHERE id = p_user_id;
  
  -- Mettre à jour session
  UPDATE user_sessions 
  SET last_heartbeat = NOW(),
      missed_heartbeats = 0
  WHERE user_id = p_user_id AND is_active = TRUE;
  
  RETURN json_build_object('success', TRUE);
  
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', FALSE, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour quitter la queue
CREATE OR REPLACE FUNCTION leave_waiting_queue_v2(p_user_id UUID) 
RETURNS JSON AS $$
BEGIN
  -- Supprimer de la queue
  DELETE FROM waiting_users WHERE id = p_user_id;
  
  -- Désactiver sessions
  UPDATE user_sessions 
  SET is_active = FALSE, disconnected_at = NOW()
  WHERE user_id = p_user_id;
  
  RETURN json_build_object('success', TRUE);
  
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', FALSE, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger pour auto-cleanup (2% des insertions)
CREATE OR REPLACE FUNCTION trigger_auto_cleanup() 
RETURNS TRIGGER AS $$
BEGIN
  -- 2% de chance de déclencher cleanup
  IF RANDOM() < 0.02 THEN
    PERFORM cleanup_inactive_sessions_v2();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Créer trigger si n'existe pas
DROP TRIGGER IF EXISTS auto_cleanup_trigger ON waiting_users;
CREATE TRIGGER auto_cleanup_trigger
  AFTER INSERT ON waiting_users
  FOR EACH ROW
  EXECUTE FUNCTION trigger_auto_cleanup();