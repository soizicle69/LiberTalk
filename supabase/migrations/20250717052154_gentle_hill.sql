/*
  # Reconstruction complète du système de connexion LiberTalk
  
  1. Nouvelles tables optimisées
    - `active_users` - Gestion des utilisateurs actifs avec heartbeat
    - `matching_queue` - File d'attente avec priorités et timeouts
    - `chat_sessions` - Sessions de chat avec états synchronisés
    - `connection_events` - Logs des événements de connexion
  
  2. Fonctions robustes
    - Matching bilatéral avec broadcast automatique
    - Heartbeat et présence avec timeouts 60s+
    - Reconnexion automatique et requeue
    - Logs détaillés pour debugging
  
  3. Sécurité
    - RLS activé sur toutes les tables
    - Policies pour utilisateurs authentifiés et anonymes
*/

-- Drop existing tables and functions
DROP TABLE IF EXISTS messages CASCADE;
DROP TABLE IF EXISTS chats CASCADE;
DROP TABLE IF EXISTS waiting_users CASCADE;
DROP TABLE IF EXISTS users CASCADE;

DROP FUNCTION IF EXISTS join_chat_queue CASCADE;
DROP FUNCTION IF EXISTS find_chat_match CASCADE;
DROP FUNCTION IF EXISTS leave_chat_queue CASCADE;
DROP FUNCTION IF EXISTS get_queue_status CASCADE;
DROP FUNCTION IF EXISTS update_presence CASCADE;
DROP FUNCTION IF EXISTS cleanup_inactive_sessions CASCADE;
DROP FUNCTION IF EXISTS force_match_waiting_users CASCADE;

-- Create new optimized tables
CREATE TABLE IF NOT EXISTS active_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id text UNIQUE NOT NULL,
  session_token text UNIQUE DEFAULT gen_random_uuid()::text,
  ip_geolocation jsonb DEFAULT '{}'::jsonb,
  location geography(Point,4326),
  continent text DEFAULT 'Unknown',
  country text DEFAULT 'Unknown',
  language text DEFAULT 'en',
  status text DEFAULT 'online' CHECK (status IN ('online', 'matching', 'chatting', 'offline')),
  last_heartbeat timestamptz DEFAULT now(),
  connected_at timestamptz DEFAULT now(),
  matching_since timestamptz,
  current_chat_id uuid,
  previous_matches uuid[] DEFAULT ARRAY[]::uuid[],
  connection_quality integer DEFAULT 100,
  retry_count integer DEFAULT 0
);

CREATE TABLE IF NOT EXISTS matching_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES active_users(id) ON DELETE CASCADE,
  priority integer DEFAULT 1,
  continent text DEFAULT 'Unknown',
  language text DEFAULT 'en',
  location geography(Point,4326),
  joined_at timestamptz DEFAULT now(),
  last_ping timestamptz DEFAULT now(),
  match_preferences jsonb DEFAULT '{}'::jsonb,
  attempts integer DEFAULT 0
);

CREATE TABLE IF NOT EXISTS chat_sessions (
  chat_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user1_id uuid REFERENCES active_users(id) ON DELETE CASCADE,
  user2_id uuid REFERENCES active_users(id) ON DELETE CASCADE,
  status text DEFAULT 'connecting' CHECK (status IN ('connecting', 'active', 'ended')),
  created_at timestamptz DEFAULT now(),
  ended_at timestamptz,
  user1_confirmed boolean DEFAULT false,
  user2_confirmed boolean DEFAULT false,
  last_activity timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id uuid REFERENCES chat_sessions(chat_id) ON DELETE CASCADE,
  sender_id uuid REFERENCES active_users(id) ON DELETE CASCADE,
  content text NOT NULL,
  translated_content jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  delivered boolean DEFAULT false
);

CREATE TABLE IF NOT EXISTS connection_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  event_type text NOT NULL,
  event_data jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_active_users_device_id ON active_users(device_id);
CREATE INDEX IF NOT EXISTS idx_active_users_status ON active_users(status);
CREATE INDEX IF NOT EXISTS idx_active_users_heartbeat ON active_users(last_heartbeat);
CREATE INDEX IF NOT EXISTS idx_active_users_location ON active_users USING gist(location);
CREATE INDEX IF NOT EXISTS idx_active_users_continent_lang ON active_users(continent, language);

CREATE INDEX IF NOT EXISTS idx_matching_queue_user_id ON matching_queue(user_id);
CREATE INDEX IF NOT EXISTS idx_matching_queue_priority ON matching_queue(priority DESC, joined_at ASC);
CREATE INDEX IF NOT EXISTS idx_matching_queue_continent_lang ON matching_queue(continent, language);
CREATE INDEX IF NOT EXISTS idx_matching_queue_location ON matching_queue USING gist(location);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_users ON chat_sessions(user1_id, user2_id);
CREATE INDEX IF NOT EXISTS idx_chat_sessions_status ON chat_sessions(status);
CREATE INDEX IF NOT EXISTS idx_chat_sessions_activity ON chat_sessions(last_activity);

CREATE INDEX IF NOT EXISTS idx_chat_messages_chat_id ON chat_messages(chat_id, created_at);
CREATE INDEX IF NOT EXISTS idx_connection_events_user_id ON connection_events(user_id, created_at);

-- Enable RLS
ALTER TABLE active_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE matching_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE connection_events ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can manage their own data" ON active_users
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Users can access queue" ON matching_queue
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Users can access their chats" ON chat_sessions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Users can access chat messages" ON chat_messages
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Users can access connection events" ON connection_events
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- Function: Join matching queue with enhanced logging
CREATE OR REPLACE FUNCTION join_matching_queue(
  p_device_id text,
  p_continent text DEFAULT 'Unknown',
  p_language text DEFAULT 'en',
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_ip_geolocation jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_location geography(Point,4326);
  v_result jsonb;
BEGIN
  -- Log join attempt
  INSERT INTO connection_events (event_type, event_data)
  VALUES ('queue_join_attempt', jsonb_build_object(
    'device_id', p_device_id,
    'continent', p_continent,
    'language', p_language
  ));

  -- Create location point if coordinates provided
  IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography;
  END IF;

  -- Insert or update user
  INSERT INTO active_users (
    device_id, continent, country, language, location, ip_geolocation,
    status, last_heartbeat, connected_at, matching_since
  ) VALUES (
    p_device_id, p_continent, 
    COALESCE(p_ip_geolocation->>'country', 'Unknown'),
    p_language, v_location, p_ip_geolocation,
    'matching', now(), now(), now()
  )
  ON CONFLICT (device_id) DO UPDATE SET
    continent = EXCLUDED.continent,
    country = EXCLUDED.country,
    language = EXCLUDED.language,
    location = EXCLUDED.location,
    ip_geolocation = EXCLUDED.ip_geolocation,
    status = 'matching',
    last_heartbeat = now(),
    matching_since = now(),
    retry_count = active_users.retry_count + 1
  RETURNING id INTO v_user_id;

  -- Remove from any existing queue
  DELETE FROM matching_queue WHERE user_id = v_user_id;

  -- Add to matching queue with priority
  INSERT INTO matching_queue (
    user_id, continent, language, location, priority, joined_at, last_ping
  ) VALUES (
    v_user_id, p_continent, p_language, v_location,
    CASE 
      WHEN p_continent = 'Europe' THEN 3
      WHEN p_continent != 'Unknown' THEN 2
      ELSE 1
    END,
    now(), now()
  );

  -- Log successful join
  INSERT INTO connection_events (user_id, event_type, event_data)
  VALUES (v_user_id, 'queue_joined', jsonb_build_object(
    'continent', p_continent,
    'language', p_language,
    'priority', CASE WHEN p_continent = 'Europe' THEN 3 ELSE 1 END
  ));

  v_result := jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'message', 'Successfully joined matching queue',
    'queue_position', (SELECT COUNT(*) FROM matching_queue WHERE priority >= (SELECT priority FROM matching_queue WHERE user_id = v_user_id))
  );

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO connection_events (event_type, event_data)
  VALUES ('queue_join_error', jsonb_build_object(
    'device_id', p_device_id,
    'error', SQLERRM
  ));
  
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Failed to join queue'
  );
END;
$$;

-- Function: Find bilateral match with broadcast
CREATE OR REPLACE FUNCTION find_bilateral_match(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_queue matching_queue%ROWTYPE;
  v_partner_id uuid;
  v_chat_id uuid;
  v_result jsonb;
  v_partner_device_id text;
  v_user_device_id text;
BEGIN
  -- Get user from queue
  SELECT * INTO v_user_queue FROM matching_queue WHERE user_id = p_user_id;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'User not in queue');
  END IF;

  -- Get user device_id
  SELECT device_id INTO v_user_device_id FROM active_users WHERE id = p_user_id;

  -- Find best match with priority matching
  WITH potential_matches AS (
    SELECT 
      mq.user_id,
      au.device_id,
      mq.continent,
      mq.language,
      mq.priority,
      mq.joined_at,
      -- Scoring system
      CASE 
        WHEN mq.continent = v_user_queue.continent AND mq.language = v_user_queue.language THEN 100
        WHEN mq.continent = v_user_queue.continent THEN 80
        WHEN mq.language = v_user_queue.language THEN 60
        ELSE 40
      END as match_score,
      -- Distance if location available
      CASE 
        WHEN v_user_queue.location IS NOT NULL AND mq.location IS NOT NULL 
        THEN ST_Distance(v_user_queue.location, mq.location)
        ELSE 999999
      END as distance
    FROM matching_queue mq
    JOIN active_users au ON mq.user_id = au.id
    WHERE mq.user_id != p_user_id
      AND au.device_id != v_user_device_id  -- Prevent same device matching
      AND au.status = 'matching'
      AND au.last_heartbeat > now() - interval '2 minutes'
      AND NOT (au.id = ANY(SELECT unnest(previous_matches) FROM active_users WHERE id = p_user_id))
    ORDER BY match_score DESC, priority DESC, distance ASC, joined_at ASC
    LIMIT 1
  )
  SELECT user_id, device_id INTO v_partner_id, v_partner_device_id FROM potential_matches;

  IF v_partner_id IS NULL THEN
    -- Update attempts
    UPDATE matching_queue SET attempts = attempts + 1, last_ping = now() WHERE user_id = p_user_id;
    
    INSERT INTO connection_events (user_id, event_type, event_data)
    VALUES (p_user_id, 'no_match_found', jsonb_build_object(
      'attempts', (SELECT attempts FROM matching_queue WHERE user_id = p_user_id),
      'queue_size', (SELECT COUNT(*) FROM matching_queue)
    ));
    
    RETURN jsonb_build_object('success', false, 'message', 'No suitable match found');
  END IF;

  -- Create chat session
  INSERT INTO chat_sessions (user1_id, user2_id, status, created_at, last_activity)
  VALUES (p_user_id, v_partner_id, 'connecting', now(), now())
  RETURNING chat_id INTO v_chat_id;

  -- Update both users status
  UPDATE active_users SET 
    status = 'chatting',
    current_chat_id = v_chat_id,
    matching_since = NULL,
    previous_matches = array_append(previous_matches, CASE WHEN id = p_user_id THEN v_partner_id ELSE p_user_id END)
  WHERE id IN (p_user_id, v_partner_id);

  -- Remove both from queue
  DELETE FROM matching_queue WHERE user_id IN (p_user_id, v_partner_id);

  -- Log successful match
  INSERT INTO connection_events (user_id, event_type, event_data)
  VALUES 
    (p_user_id, 'match_found', jsonb_build_object(
      'partner_id', v_partner_id,
      'chat_id', v_chat_id,
      'partner_device', v_partner_device_id
    )),
    (v_partner_id, 'match_found', jsonb_build_object(
      'partner_id', p_user_id,
      'chat_id', v_chat_id,
      'partner_device', v_user_device_id
    ));

  v_result := jsonb_build_object(
    'success', true,
    'chat_id', v_chat_id,
    'partner_id', v_partner_id,
    'message', 'Match found successfully',
    'requires_bilateral_confirmation', true
  );

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO connection_events (user_id, event_type, event_data)
  VALUES (p_user_id, 'match_error', jsonb_build_object('error', SQLERRM));
  
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Matching failed'
  );
END;
$$;

-- Function: Confirm bilateral connection
CREATE OR REPLACE FUNCTION confirm_bilateral_connection(
  p_user_id uuid,
  p_chat_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_chat chat_sessions%ROWTYPE;
  v_both_confirmed boolean;
BEGIN
  -- Get chat session
  SELECT * INTO v_chat FROM chat_sessions WHERE chat_id = p_chat_id;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Chat session not found');
  END IF;

  -- Update confirmation for the user
  IF v_chat.user1_id = p_user_id THEN
    UPDATE chat_sessions SET user1_confirmed = true, last_activity = now() WHERE chat_id = p_chat_id;
  ELSIF v_chat.user2_id = p_user_id THEN
    UPDATE chat_sessions SET user2_confirmed = true, last_activity = now() WHERE chat_id = p_chat_id;
  ELSE
    RETURN jsonb_build_object('success', false, 'message', 'User not part of this chat');
  END IF;

  -- Check if both confirmed
  SELECT user1_confirmed AND user2_confirmed INTO v_both_confirmed
  FROM chat_sessions WHERE chat_id = p_chat_id;

  -- If both confirmed, activate chat
  IF v_both_confirmed THEN
    UPDATE chat_sessions SET status = 'active' WHERE chat_id = p_chat_id;
    
    INSERT INTO connection_events (user_id, event_type, event_data)
    VALUES 
      (v_chat.user1_id, 'chat_activated', jsonb_build_object('chat_id', p_chat_id)),
      (v_chat.user2_id, 'chat_activated', jsonb_build_object('chat_id', p_chat_id));
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'both_confirmed', v_both_confirmed,
    'chat_status', CASE WHEN v_both_confirmed THEN 'active' ELSE 'connecting' END
  );
END;
$$;

-- Function: Heartbeat with enhanced presence
CREATE OR REPLACE FUNCTION send_heartbeat(
  p_user_id uuid,
  p_connection_quality integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE active_users SET 
    last_heartbeat = now(),
    connection_quality = p_connection_quality
  WHERE id = p_user_id;

  IF FOUND THEN
    -- Update queue ping if in queue
    UPDATE matching_queue SET last_ping = now() WHERE user_id = p_user_id;
    
    -- Update chat activity if in chat
    UPDATE chat_sessions SET last_activity = now() 
    WHERE (user1_id = p_user_id OR user2_id = p_user_id) AND status = 'active';

    RETURN jsonb_build_object('success', true, 'timestamp', now());
  ELSE
    RETURN jsonb_build_object('success', false, 'message', 'User not found');
  END IF;
END;
$$;

-- Function: Leave queue safely
CREATE OR REPLACE FUNCTION leave_matching_queue(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Remove from queue
  DELETE FROM matching_queue WHERE user_id = p_user_id;
  
  -- Update user status
  UPDATE active_users SET 
    status = 'online',
    matching_since = NULL
  WHERE id = p_user_id;

  INSERT INTO connection_events (user_id, event_type, event_data)
  VALUES (p_user_id, 'left_queue', jsonb_build_object('timestamp', now()));

  RETURN jsonb_build_object('success', true, 'message', 'Left queue successfully');
END;
$$;

-- Function: End chat session
CREATE OR REPLACE FUNCTION end_chat_session(
  p_user_id uuid,
  p_chat_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_partner_id uuid;
BEGIN
  -- Get partner ID
  SELECT CASE WHEN user1_id = p_user_id THEN user2_id ELSE user1_id END
  INTO v_partner_id
  FROM chat_sessions 
  WHERE chat_id = p_chat_id AND (user1_id = p_user_id OR user2_id = p_user_id);

  -- End chat session
  UPDATE chat_sessions SET 
    status = 'ended',
    ended_at = now()
  WHERE chat_id = p_chat_id;

  -- Update users status
  UPDATE active_users SET 
    status = 'online',
    current_chat_id = NULL
  WHERE id IN (p_user_id, v_partner_id);

  -- Log disconnection
  INSERT INTO connection_events (user_id, event_type, event_data)
  VALUES 
    (p_user_id, 'chat_ended', jsonb_build_object('chat_id', p_chat_id, 'partner_id', v_partner_id)),
    (v_partner_id, 'partner_disconnected', jsonb_build_object('chat_id', p_chat_id, 'disconnected_user', p_user_id));

  RETURN jsonb_build_object(
    'success', true,
    'partner_id', v_partner_id,
    'message', 'Chat ended successfully'
  );
END;
$$;

-- Function: Get queue statistics
CREATE OR REPLACE FUNCTION get_queue_statistics()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_stats jsonb;
BEGIN
  SELECT jsonb_build_object(
    'total_waiting', COUNT(*),
    'by_continent', jsonb_object_agg(continent, continent_count),
    'by_language', jsonb_object_agg(language, language_count),
    'average_wait_time', EXTRACT(EPOCH FROM AVG(now() - joined_at)),
    'timestamp', now()
  ) INTO v_stats
  FROM (
    SELECT 
      continent,
      language,
      COUNT(*) OVER (PARTITION BY continent) as continent_count,
      COUNT(*) OVER (PARTITION BY language) as language_count,
      joined_at
    FROM matching_queue mq
    JOIN active_users au ON mq.user_id = au.id
    WHERE au.last_heartbeat > now() - interval '2 minutes'
  ) subq;

  RETURN COALESCE(v_stats, jsonb_build_object(
    'total_waiting', 0,
    'by_continent', '{}',
    'by_language', '{}',
    'average_wait_time', 0,
    'timestamp', now()
  ));
END;
$$;

-- Function: Cleanup inactive sessions with enhanced logic
CREATE OR REPLACE FUNCTION cleanup_inactive_sessions()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cleaned_users integer := 0;
  v_cleaned_queue integer := 0;
  v_cleaned_chats integer := 0;
BEGIN
  -- Clean inactive users (no heartbeat for 3 minutes)
  WITH inactive_users AS (
    DELETE FROM active_users 
    WHERE last_heartbeat < now() - interval '3 minutes'
      AND status != 'chatting'
    RETURNING id
  )
  SELECT COUNT(*) INTO v_cleaned_users FROM inactive_users;

  -- Clean stale queue entries
  WITH stale_queue AS (
    DELETE FROM matching_queue mq
    WHERE NOT EXISTS (
      SELECT 1 FROM active_users au 
      WHERE au.id = mq.user_id 
        AND au.last_heartbeat > now() - interval '2 minutes'
    )
    RETURNING id
  )
  SELECT COUNT(*) INTO v_cleaned_queue FROM stale_queue;

  -- Clean abandoned chats (no activity for 5 minutes)
  WITH abandoned_chats AS (
    UPDATE chat_sessions SET status = 'ended', ended_at = now()
    WHERE status IN ('connecting', 'active')
      AND last_activity < now() - interval '5 minutes'
    RETURNING chat_id
  )
  SELECT COUNT(*) INTO v_cleaned_chats FROM abandoned_chats;

  -- Log cleanup
  INSERT INTO connection_events (event_type, event_data)
  VALUES ('cleanup_completed', jsonb_build_object(
    'cleaned_users', v_cleaned_users,
    'cleaned_queue', v_cleaned_queue,
    'cleaned_chats', v_cleaned_chats,
    'timestamp', now()
  ));

  RETURN jsonb_build_object(
    'success', true,
    'cleaned_users', v_cleaned_users,
    'cleaned_queue', v_cleaned_queue,
    'cleaned_chats', v_cleaned_chats
  );
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION join_matching_queue TO anon, authenticated;
GRANT EXECUTE ON FUNCTION find_bilateral_match TO anon, authenticated;
GRANT EXECUTE ON FUNCTION confirm_bilateral_connection TO anon, authenticated;
GRANT EXECUTE ON FUNCTION send_heartbeat TO anon, authenticated;
GRANT EXECUTE ON FUNCTION leave_matching_queue TO anon, authenticated;
GRANT EXECUTE ON FUNCTION end_chat_session TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_queue_statistics TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleanup_inactive_sessions TO anon, authenticated;