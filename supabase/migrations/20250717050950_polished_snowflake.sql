/*
  # Correction des connexions multi-appareils

  1. Fonctions améliorées
    - Gestion robuste des sessions multiples
    - Prévention des conflits de device_id
    - Matching amélioré avec timeouts
    - Nettoyage intelligent des sessions

  2. Sécurité
    - Policies mises à jour
    - Gestion des sessions par device_id
    - Prévention des doublons
*/

-- Supprimer toutes les fonctions existantes
DROP FUNCTION IF EXISTS join_chat_queue(uuid, double precision, double precision, text, text) CASCADE;
DROP FUNCTION IF EXISTS find_chat_match(uuid) CASCADE;
DROP FUNCTION IF EXISTS leave_chat_queue(uuid) CASCADE;
DROP FUNCTION IF EXISTS get_queue_status() CASCADE;
DROP FUNCTION IF EXISTS update_presence(uuid) CASCADE;
DROP FUNCTION IF EXISTS cleanup_inactive_sessions() CASCADE;
DROP FUNCTION IF EXISTS force_match_waiting_users() CASCADE;

-- Fonction pour rejoindre la file d'attente (améliorée)
CREATE OR REPLACE FUNCTION join_chat_queue(
  p_user_id uuid,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_continent text DEFAULT 'Unknown',
  p_language text DEFAULT 'en'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result jsonb;
  v_existing_entry record;
BEGIN
  -- Nettoyer d'abord les sessions inactives
  PERFORM cleanup_inactive_sessions();
  
  -- Vérifier si l'utilisateur est déjà dans la file
  SELECT * INTO v_existing_entry
  FROM waiting_users 
  WHERE user_id = p_user_id;
  
  -- Si déjà présent, mettre à jour
  IF FOUND THEN
    UPDATE waiting_users 
    SET 
      latitude = COALESCE(p_latitude, latitude),
      longitude = COALESCE(p_longitude, longitude),
      continent = COALESCE(p_continent, continent),
      language = COALESCE(p_language, language),
      last_ping = now()
    WHERE user_id = p_user_id;
    
    v_result := jsonb_build_object(
      'success', true,
      'message', 'Updated queue position',
      'user_id', p_user_id
    );
  ELSE
    -- Insérer nouvelle entrée
    INSERT INTO waiting_users (
      user_id, 
      latitude, 
      longitude, 
      continent, 
      language,
      joined_at,
      last_ping
    ) VALUES (
      p_user_id, 
      p_latitude, 
      p_longitude, 
      p_continent, 
      p_language,
      now(),
      now()
    );
    
    v_result := jsonb_build_object(
      'success', true,
      'message', 'Joined queue successfully',
      'user_id', p_user_id
    );
  END IF;
  
  -- Mettre à jour le statut utilisateur
  UPDATE users 
  SET 
    status = 'waiting',
    matching_since = now(),
    last_activity = now(),
    connection_status = 'online'
  WHERE id = p_user_id;
  
  RETURN v_result;
  
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM,
      'message', 'Failed to join queue'
    );
END;
$$;

-- Fonction de matching améliorée avec gestion multi-appareils
CREATE OR REPLACE FUNCTION find_chat_match(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_record record;
  v_partner_id uuid;
  v_chat_id uuid;
  v_result jsonb;
  v_match_found boolean := false;
BEGIN
  -- Nettoyer les sessions inactives
  PERFORM cleanup_inactive_sessions();
  
  -- Récupérer les infos de l'utilisateur
  SELECT wu.*, u.previous_matches, u.device_id
  INTO v_user_record
  FROM waiting_users wu
  JOIN users u ON wu.user_id = u.id
  WHERE wu.user_id = p_user_id
  AND wu.last_ping > now() - interval '2 minutes';
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'User not in queue or inactive'
    );
  END IF;
  
  -- Stratégie de matching par priorité
  
  -- 1. Même continent + même langue (excluant les matches précédents et même device)
  IF NOT v_match_found THEN
    SELECT wu.user_id INTO v_partner_id
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.user_id != p_user_id
    AND wu.continent = v_user_record.continent
    AND wu.language = v_user_record.language
    AND wu.last_ping > now() - interval '2 minutes'
    AND NOT (v_user_record.previous_matches @> ARRAY[wu.user_id])
    AND u.device_id != v_user_record.device_id
    AND u.status = 'waiting'
    AND u.connection_status = 'online'
    ORDER BY wu.joined_at ASC
    LIMIT 1;
    
    IF FOUND THEN
      v_match_found := true;
    END IF;
  END IF;
  
  -- 2. Même continent (différente langue)
  IF NOT v_match_found THEN
    SELECT wu.user_id INTO v_partner_id
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.user_id != p_user_id
    AND wu.continent = v_user_record.continent
    AND wu.last_ping > now() - interval '2 minutes'
    AND NOT (v_user_record.previous_matches @> ARRAY[wu.user_id])
    AND u.device_id != v_user_record.device_id
    AND u.status = 'waiting'
    AND u.connection_status = 'online'
    ORDER BY wu.joined_at ASC
    LIMIT 1;
    
    IF FOUND THEN
      v_match_found := true;
    END IF;
  END IF;
  
  -- 3. Même langue (différent continent)
  IF NOT v_match_found THEN
    SELECT wu.user_id INTO v_partner_id
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.user_id != p_user_id
    AND wu.language = v_user_record.language
    AND wu.last_ping > now() - interval '2 minutes'
    AND NOT (v_user_record.previous_matches @> ARRAY[wu.user_id])
    AND u.device_id != v_user_record.device_id
    AND u.status = 'waiting'
    AND u.connection_status = 'online'
    ORDER BY wu.joined_at ASC
    LIMIT 1;
    
    IF FOUND THEN
      v_match_found := true;
    END IF;
  END IF;
  
  -- 4. Matching global (dernier recours)
  IF NOT v_match_found THEN
    SELECT wu.user_id INTO v_partner_id
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.user_id != p_user_id
    AND wu.last_ping > now() - interval '2 minutes'
    AND NOT (v_user_record.previous_matches @> ARRAY[wu.user_id])
    AND u.device_id != v_user_record.device_id
    AND u.status = 'waiting'
    AND u.connection_status = 'online'
    ORDER BY wu.joined_at ASC
    LIMIT 1;
    
    IF FOUND THEN
      v_match_found := true;
    END IF;
  END IF;
  
  -- Si aucun match trouvé
  IF NOT v_match_found THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'No suitable partner found'
    );
  END IF;
  
  -- Créer le chat
  v_chat_id := gen_random_uuid();
  
  INSERT INTO chats (chat_id, user1_id, user2_id, created_at, status)
  VALUES (v_chat_id, p_user_id, v_partner_id, now(), 'active');
  
  -- Supprimer les deux utilisateurs de la file d'attente
  DELETE FROM waiting_users WHERE user_id IN (p_user_id, v_partner_id);
  
  -- Mettre à jour le statut des utilisateurs
  UPDATE users 
  SET 
    status = 'chatting',
    matching_since = NULL,
    last_activity = now(),
    previous_matches = array_append(previous_matches, CASE WHEN id = p_user_id THEN v_partner_id ELSE p_user_id END),
    matching_attempts = matching_attempts + 1,
    last_match_attempt = now()
  WHERE id IN (p_user_id, v_partner_id);
  
  RETURN jsonb_build_object(
    'success', true,
    'chat_id', v_chat_id,
    'partner_id', v_partner_id,
    'message', 'Match found successfully'
  );
  
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM,
      'message', 'Error during matching process'
    );
END;
$$;

-- Fonction pour quitter la file d'attente
CREATE OR REPLACE FUNCTION leave_chat_queue(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Supprimer de la file d'attente
  DELETE FROM waiting_users WHERE user_id = p_user_id;
  
  -- Mettre à jour le statut utilisateur
  UPDATE users 
  SET 
    status = 'disconnected',
    matching_since = NULL,
    connection_status = 'offline',
    last_activity = now()
  WHERE id = p_user_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Left queue successfully'
  );
  
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;

-- Fonction pour obtenir les statistiques de la file
CREATE OR REPLACE FUNCTION get_queue_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total_waiting integer;
  v_by_continent jsonb;
  v_by_language jsonb;
BEGIN
  -- Nettoyer d'abord
  PERFORM cleanup_inactive_sessions();
  
  -- Compter le total
  SELECT COUNT(*) INTO v_total_waiting
  FROM waiting_users wu
  JOIN users u ON wu.user_id = u.id
  WHERE wu.last_ping > now() - interval '2 minutes'
  AND u.connection_status = 'online';
  
  -- Statistiques par continent
  SELECT jsonb_object_agg(continent, cnt) INTO v_by_continent
  FROM (
    SELECT wu.continent, COUNT(*) as cnt
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.last_ping > now() - interval '2 minutes'
    AND u.connection_status = 'online'
    GROUP BY wu.continent
  ) t;
  
  -- Statistiques par langue
  SELECT jsonb_object_agg(language, cnt) INTO v_by_language
  FROM (
    SELECT wu.language, COUNT(*) as cnt
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.last_ping > now() - interval '2 minutes'
    AND u.connection_status = 'online'
    GROUP BY wu.language
  ) t;
  
  RETURN jsonb_build_object(
    'total_waiting', COALESCE(v_total_waiting, 0),
    'by_continent', COALESCE(v_by_continent, '{}'::jsonb),
    'by_language', COALESCE(v_by_language, '{}'::jsonb),
    'timestamp', now()
  );
END;
$$;

-- Fonction pour mettre à jour la présence
CREATE OR REPLACE FUNCTION update_presence(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Mettre à jour la présence utilisateur
  UPDATE users 
  SET 
    last_activity = now(),
    last_seen = now(),
    connection_status = 'online'
  WHERE id = p_user_id;
  
  -- Mettre à jour dans la file d'attente si présent
  UPDATE waiting_users 
  SET last_ping = now()
  WHERE user_id = p_user_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'timestamp', now()
  );
  
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;

-- Fonction de nettoyage améliorée
CREATE OR REPLACE FUNCTION cleanup_inactive_sessions()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cleaned_users integer := 0;
  v_cleaned_queue integer := 0;
  v_ended_chats integer := 0;
BEGIN
  -- Nettoyer la file d'attente (inactifs depuis plus de 2 minutes)
  DELETE FROM waiting_users 
  WHERE last_ping < now() - interval '2 minutes';
  
  GET DIAGNOSTICS v_cleaned_queue = ROW_COUNT;
  
  -- Marquer les utilisateurs inactifs comme déconnectés
  UPDATE users 
  SET 
    status = 'disconnected',
    connection_status = 'offline',
    matching_since = NULL
  WHERE last_activity < now() - interval '3 minutes'
  AND connection_status != 'offline';
  
  GET DIAGNOSTICS v_cleaned_users = ROW_COUNT;
  
  -- Terminer les chats avec des utilisateurs inactifs
  UPDATE chats 
  SET 
    status = 'ended',
    ended_at = now()
  WHERE status = 'active'
  AND (
    user1_id IN (
      SELECT id FROM users 
      WHERE last_activity < now() - interval '3 minutes'
    )
    OR user2_id IN (
      SELECT id FROM users 
      WHERE last_activity < now() - interval '3 minutes'
    )
  );
  
  GET DIAGNOSTICS v_ended_chats = ROW_COUNT;
  
  -- Supprimer les anciens utilisateurs (plus de 24h)
  DELETE FROM users 
  WHERE connected_at < now() - interval '24 hours'
  AND connection_status = 'offline';
  
  RETURN jsonb_build_object(
    'success', true,
    'cleaned_users', v_cleaned_users,
    'cleaned_queue', v_cleaned_queue,
    'ended_chats', v_ended_chats,
    'timestamp', now()
  );
  
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;

-- Fonction pour forcer le matching (utile pour le debug)
CREATE OR REPLACE FUNCTION force_match_waiting_users()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user1 uuid;
  v_user2 uuid;
  v_chat_id uuid;
  v_matches_created integer := 0;
BEGIN
  -- Nettoyer d'abord
  PERFORM cleanup_inactive_sessions();
  
  -- Créer des matches pour tous les utilisateurs en attente
  LOOP
    -- Prendre les deux premiers utilisateurs en attente
    SELECT wu1.user_id, wu2.user_id
    INTO v_user1, v_user2
    FROM waiting_users wu1
    JOIN waiting_users wu2 ON wu1.user_id < wu2.user_id
    JOIN users u1 ON wu1.user_id = u1.id
    JOIN users u2 ON wu2.user_id = u2.id
    WHERE wu1.last_ping > now() - interval '2 minutes'
    AND wu2.last_ping > now() - interval '2 minutes'
    AND u1.connection_status = 'online'
    AND u2.connection_status = 'online'
    AND u1.device_id != u2.device_id
    ORDER BY wu1.joined_at, wu2.joined_at
    LIMIT 1;
    
    EXIT WHEN NOT FOUND;
    
    -- Créer le chat
    v_chat_id := gen_random_uuid();
    
    INSERT INTO chats (chat_id, user1_id, user2_id, created_at, status)
    VALUES (v_chat_id, v_user1, v_user2, now(), 'active');
    
    -- Supprimer de la file d'attente
    DELETE FROM waiting_users WHERE user_id IN (v_user1, v_user2);
    
    -- Mettre à jour les utilisateurs
    UPDATE users 
    SET 
      status = 'chatting',
      matching_since = NULL,
      last_activity = now(),
      previous_matches = array_append(previous_matches, CASE WHEN id = v_user1 THEN v_user2 ELSE v_user1 END)
    WHERE id IN (v_user1, v_user2);
    
    v_matches_created := v_matches_created + 1;
  END LOOP;
  
  RETURN jsonb_build_object(
    'success', true,
    'matches_created', v_matches_created,
    'timestamp', now()
  );
  
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;

-- Accorder les permissions
GRANT EXECUTE ON FUNCTION join_chat_queue(uuid, double precision, double precision, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION find_chat_match(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION leave_chat_queue(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_queue_status() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION update_presence(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleanup_inactive_sessions() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION force_match_waiting_users() TO anon, authenticated;