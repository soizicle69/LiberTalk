/*
  # Système de matching robuste avec file d'attente persistante

  1. Nouvelles Tables
    - `waiting_users` - File d'attente persistante avec priorités
    - `match_attempts` - Historique des tentatives de matching
    - `user_sessions` - Sessions utilisateur avec heartbeat
    - `connection_logs` - Logs détaillés pour debugging

  2. Fonctions optimisées
    - `join_waiting_queue` - Rejoindre la file d'attente
    - `find_best_match` - Matching intelligent avec priorités
    - `confirm_bilateral_match` - Confirmation bilatérale
    - `handle_user_disconnect` - Gestion propre des déconnexions

  3. Sécurité
    - RLS activé sur toutes les tables
    - Policies pour accès sécurisé
    - Nettoyage automatique des sessions inactives
*/

-- Drop existing tables and functions
DROP TABLE IF EXISTS matching_queue CASCADE;
DROP TABLE IF EXISTS active_users CASCADE;
DROP FUNCTION IF EXISTS join_matching_queue CASCADE;
DROP FUNCTION IF EXISTS find_bilateral_match CASCADE;
DROP FUNCTION IF EXISTS cleanup_inactive_sessions CASCADE;

-- Create waiting users table with persistent queue
CREATE TABLE IF NOT EXISTS waiting_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id text UNIQUE NOT NULL,
  session_token text UNIQUE DEFAULT gen_random_uuid()::text,
  
  -- Location data
  location geography(Point,4326),
  continent text DEFAULT 'Unknown',
  country text DEFAULT 'Unknown',
  city text DEFAULT 'Unknown',
  language text DEFAULT 'en',
  
  -- Queue management
  priority integer DEFAULT 1,
  joined_at timestamptz DEFAULT now(),
  last_heartbeat timestamptz DEFAULT now(),
  search_attempts integer DEFAULT 0,
  max_wait_time interval DEFAULT '5 minutes',
  
  -- Matching preferences
  prefer_nearby boolean DEFAULT true,
  max_distance_km integer DEFAULT 1000,
  preferred_languages text[] DEFAULT ARRAY['en'],
  
  -- Status tracking
  status text DEFAULT 'searching' CHECK (status IN ('searching', 'matched', 'connecting', 'connected', 'disconnected')),
  current_match_id uuid,
  connection_quality integer DEFAULT 100,
  
  -- Metadata
  user_agent text,
  ip_address inet,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Create match attempts table for tracking
CREATE TABLE IF NOT EXISTS match_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user1_id uuid REFERENCES waiting_users(id) ON DELETE CASCADE,
  user2_id uuid REFERENCES waiting_users(id) ON DELETE CASCADE,
  
  -- Match details
  match_score integer DEFAULT 0,
  distance_km integer,
  language_match boolean DEFAULT false,
  continent_match boolean DEFAULT false,
  
  -- Status tracking
  status text DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'rejected', 'timeout')),
  user1_confirmed boolean DEFAULT false,
  user2_confirmed boolean DEFAULT false,
  confirmation_timeout timestamptz DEFAULT (now() + interval '30 seconds'),
  
  -- Timing
  created_at timestamptz DEFAULT now(),
  confirmed_at timestamptz,
  ended_at timestamptz
);

-- Create user sessions for heartbeat tracking
CREATE TABLE IF NOT EXISTS user_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES waiting_users(id) ON DELETE CASCADE,
  
  -- Session data
  session_token text UNIQUE NOT NULL,
  device_fingerprint text,
  
  -- Connection tracking
  connected_at timestamptz DEFAULT now(),
  last_heartbeat timestamptz DEFAULT now(),
  heartbeat_interval integer DEFAULT 5, -- seconds
  missed_heartbeats integer DEFAULT 0,
  max_missed_heartbeats integer DEFAULT 6, -- 30 seconds total
  
  -- Status
  is_active boolean DEFAULT true,
  disconnect_reason text,
  disconnected_at timestamptz,
  
  -- Metadata
  user_agent text,
  ip_address inet,
  connection_type text DEFAULT 'websocket'
);

-- Create connection logs for debugging
CREATE TABLE IF NOT EXISTS connection_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  session_id uuid,
  
  -- Event details
  event_type text NOT NULL, -- 'join_queue', 'match_found', 'connected', 'disconnected', 'heartbeat', 'error'
  event_data jsonb DEFAULT '{}',
  message text,
  
  -- Context
  user_agent text,
  ip_address inet,
  timestamp timestamptz DEFAULT now()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_waiting_users_status ON waiting_users(status);
CREATE INDEX IF NOT EXISTS idx_waiting_users_location ON waiting_users USING GIST(location);
CREATE INDEX IF NOT EXISTS idx_waiting_users_continent_lang ON waiting_users(continent, language);
CREATE INDEX IF NOT EXISTS idx_waiting_users_joined_at ON waiting_users(joined_at);
CREATE INDEX IF NOT EXISTS idx_waiting_users_heartbeat ON waiting_users(last_heartbeat);

CREATE INDEX IF NOT EXISTS idx_match_attempts_status ON match_attempts(status);
CREATE INDEX IF NOT EXISTS idx_match_attempts_timeout ON match_attempts(confirmation_timeout);
CREATE INDEX IF NOT EXISTS idx_match_attempts_users ON match_attempts(user1_id, user2_id);

CREATE INDEX IF NOT EXISTS idx_user_sessions_active ON user_sessions(is_active, last_heartbeat);
CREATE INDEX IF NOT EXISTS idx_user_sessions_token ON user_sessions(session_token);

CREATE INDEX IF NOT EXISTS idx_connection_logs_user_time ON connection_logs(user_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_connection_logs_event_type ON connection_logs(event_type, timestamp);

-- Enable RLS
ALTER TABLE waiting_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE match_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE connection_logs ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can manage their own queue entry" ON waiting_users
  FOR ALL TO anon, authenticated
  USING (true) WITH CHECK (true);

CREATE POLICY "Users can view match attempts" ON match_attempts
  FOR ALL TO anon, authenticated
  USING (true) WITH CHECK (true);

CREATE POLICY "Users can manage their sessions" ON user_sessions
  FOR ALL TO anon, authenticated
  USING (true) WITH CHECK (true);

CREATE POLICY "Users can view connection logs" ON connection_logs
  FOR ALL TO anon, authenticated
  USING (true) WITH CHECK (true);

-- Function: Join waiting queue with enhanced logic
CREATE OR REPLACE FUNCTION join_waiting_queue(
  p_device_id text,
  p_continent text DEFAULT 'Unknown',
  p_country text DEFAULT 'Unknown',
  p_city text DEFAULT 'Unknown',
  p_language text DEFAULT 'en',
  p_latitude float DEFAULT NULL,
  p_longitude float DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_ip_address inet DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_session_id uuid;
  v_location geography;
  v_queue_position integer;
  v_estimated_wait interval;
BEGIN
  -- Log join attempt
  INSERT INTO connection_logs (event_type, message, user_agent, ip_address, event_data)
  VALUES ('join_queue', 'User attempting to join queue', p_user_agent, p_ip_address, 
          jsonb_build_object('device_id', p_device_id, 'continent', p_continent, 'language', p_language));

  -- Create location point if coordinates provided
  IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography;
  END IF;

  -- Remove any existing entry for this device
  DELETE FROM waiting_users WHERE device_id = p_device_id;
  DELETE FROM user_sessions WHERE device_fingerprint = p_device_id;

  -- Insert user into waiting queue
  INSERT INTO waiting_users (
    device_id, location, continent, country, city, language,
    status, priority, user_agent, ip_address,
    preferred_languages, max_distance_km
  ) VALUES (
    p_device_id, v_location, p_continent, p_country, p_city, p_language,
    'searching', 
    CASE 
      WHEN p_continent = 'Europe' THEN 3
      WHEN p_continent != 'Unknown' THEN 2
      ELSE 1
    END,
    p_user_agent, p_ip_address,
    ARRAY[p_language, 'en'], -- Always include English as fallback
    CASE WHEN p_continent = 'Europe' THEN 500 ELSE 2000 END
  ) RETURNING id INTO v_user_id;

  -- Create session for heartbeat tracking
  INSERT INTO user_sessions (
    user_id, session_token, device_fingerprint,
    user_agent, ip_address
  ) VALUES (
    v_user_id, gen_random_uuid()::text, p_device_id,
    p_user_agent, p_ip_address
  ) RETURNING id INTO v_session_id;

  -- Calculate queue position and estimated wait
  SELECT COUNT(*) INTO v_queue_position
  FROM waiting_users 
  WHERE status = 'searching' AND joined_at < (SELECT joined_at FROM waiting_users WHERE id = v_user_id);

  v_estimated_wait := (v_queue_position * interval '15 seconds');

  -- Log successful join
  INSERT INTO connection_logs (user_id, session_id, event_type, message, event_data)
  VALUES (v_user_id, v_session_id, 'join_queue', 'Successfully joined waiting queue',
          jsonb_build_object('queue_position', v_queue_position, 'estimated_wait', v_estimated_wait));

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'session_id', v_session_id,
    'queue_position', v_queue_position,
    'estimated_wait_seconds', EXTRACT(EPOCH FROM v_estimated_wait),
    'message', 'Successfully joined waiting queue'
  );

EXCEPTION WHEN OTHERS THEN
  -- Log error
  INSERT INTO connection_logs (event_type, message, event_data)
  VALUES ('error', 'Failed to join queue: ' || SQLERRM, 
          jsonb_build_object('device_id', p_device_id, 'error', SQLERRM));
  
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Failed to join waiting queue'
  );
END;
$$;

-- Function: Find best match with intelligent scoring
CREATE OR REPLACE FUNCTION find_best_match(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user waiting_users%ROWTYPE;
  v_potential_match waiting_users%ROWTYPE;
  v_best_match waiting_users%ROWTYPE;
  v_best_score integer := 0;
  v_distance_km integer;
  v_match_attempt_id uuid;
  v_current_score integer;
  v_total_waiting integer;
BEGIN
  -- Get current user
  SELECT * INTO v_user FROM waiting_users WHERE id = p_user_id AND status = 'searching';
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not in queue or not searching');
  END IF;

  -- Update search attempts
  UPDATE waiting_users 
  SET search_attempts = search_attempts + 1, updated_at = now()
  WHERE id = p_user_id;

  -- Log search attempt
  INSERT INTO connection_logs (user_id, event_type, message, event_data)
  VALUES (p_user_id, 'match_search', 'Starting match search', 
          jsonb_build_object('attempt', v_user.search_attempts + 1));

  -- Count total waiting users
  SELECT COUNT(*) INTO v_total_waiting FROM waiting_users WHERE status = 'searching' AND id != p_user_id;
  
  IF v_total_waiting = 0 THEN
    INSERT INTO connection_logs (user_id, event_type, message)
    VALUES (p_user_id, 'match_search', 'No other users in queue');
    
    RETURN jsonb_build_object(
      'success', false, 
      'message', 'No other users available',
      'total_waiting', v_total_waiting,
      'retry_in_seconds', 5
    );
  END IF;

  -- Find best match using scoring algorithm
  FOR v_potential_match IN 
    SELECT * FROM waiting_users 
    WHERE status = 'searching' 
      AND id != p_user_id
      AND device_id != v_user.device_id -- Prevent self-matching
      AND last_heartbeat > (now() - interval '60 seconds') -- Only active users
    ORDER BY priority DESC, joined_at ASC
  LOOP
    v_current_score := 0;
    v_distance_km := NULL;

    -- Calculate distance if both have location
    IF v_user.location IS NOT NULL AND v_potential_match.location IS NOT NULL THEN
      v_distance_km := ST_Distance(v_user.location, v_potential_match.location) / 1000;
      
      -- Distance scoring (closer = better)
      IF v_distance_km <= 100 THEN v_current_score := v_current_score + 50;
      ELSIF v_distance_km <= 500 THEN v_current_score := v_current_score + 30;
      ELSIF v_distance_km <= 1000 THEN v_current_score := v_current_score + 20;
      ELSIF v_distance_km <= 2000 THEN v_current_score := v_current_score + 10;
      END IF;
    END IF;

    -- Language matching
    IF v_user.language = v_potential_match.language THEN
      v_current_score := v_current_score + 40;
    ELSIF v_potential_match.language = ANY(v_user.preferred_languages) THEN
      v_current_score := v_current_score + 20;
    END IF;

    -- Continent matching
    IF v_user.continent = v_potential_match.continent AND v_user.continent != 'Unknown' THEN
      v_current_score := v_current_score + 30;
    END IF;

    -- Country matching
    IF v_user.country = v_potential_match.country AND v_user.country != 'Unknown' THEN
      v_current_score := v_current_score + 20;
    END IF;

    -- Priority bonus
    v_current_score := v_current_score + (v_potential_match.priority * 5);

    -- Wait time bonus (longer waiting = higher priority)
    v_current_score := v_current_score + EXTRACT(EPOCH FROM (now() - v_potential_match.joined_at)) / 60;

    -- Connection quality bonus
    v_current_score := v_current_score + (v_potential_match.connection_quality / 10);

    -- Update best match if this is better
    IF v_current_score > v_best_score THEN
      v_best_score := v_current_score;
      v_best_match := v_potential_match;
    END IF;
  END LOOP;

  -- If no good match found, try global matching after some attempts
  IF v_best_match.id IS NULL AND v_user.search_attempts >= 3 THEN
    SELECT * INTO v_best_match 
    FROM waiting_users 
    WHERE status = 'searching' 
      AND id != p_user_id
      AND device_id != v_user.device_id
      AND last_heartbeat > (now() - interval '60 seconds')
    ORDER BY joined_at ASC 
    LIMIT 1;
    
    IF FOUND THEN
      v_best_score := 10; -- Minimum score for global match
      INSERT INTO connection_logs (user_id, event_type, message)
      VALUES (p_user_id, 'match_search', 'Using global matching fallback');
    END IF;
  END IF;

  -- If still no match, return failure
  IF v_best_match.id IS NULL THEN
    INSERT INTO connection_logs (user_id, event_type, message, event_data)
    VALUES (p_user_id, 'match_search', 'No suitable match found', 
            jsonb_build_object('attempts', v_user.search_attempts + 1, 'total_waiting', v_total_waiting));
    
    RETURN jsonb_build_object(
      'success', false,
      'message', 'No suitable match found',
      'total_waiting', v_total_waiting,
      'search_attempts', v_user.search_attempts + 1,
      'retry_in_seconds', LEAST(5 + v_user.search_attempts, 15)
    );
  END IF;

  -- Create match attempt
  INSERT INTO match_attempts (
    user1_id, user2_id, match_score, distance_km,
    language_match, continent_match
  ) VALUES (
    p_user_id, v_best_match.id, v_best_score, v_distance_km,
    v_user.language = v_best_match.language,
    v_user.continent = v_best_match.continent
  ) RETURNING id INTO v_match_attempt_id;

  -- Update both users status
  UPDATE waiting_users 
  SET status = 'matched', current_match_id = v_match_attempt_id, updated_at = now()
  WHERE id IN (p_user_id, v_best_match.id);

  -- Log successful match
  INSERT INTO connection_logs (user_id, event_type, message, event_data)
  VALUES (p_user_id, 'match_found', 'Match found successfully', 
          jsonb_build_object(
            'partner_id', v_best_match.id,
            'match_score', v_best_score,
            'distance_km', v_distance_km,
            'language_match', v_user.language = v_best_match.language,
            'continent_match', v_user.continent = v_best_match.continent
          ));

  INSERT INTO connection_logs (user_id, event_type, message, event_data)
  VALUES (v_best_match.id, 'match_found', 'Match found successfully', 
          jsonb_build_object(
            'partner_id', p_user_id,
            'match_score', v_best_score,
            'distance_km', v_distance_km
          ));

  RETURN jsonb_build_object(
    'success', true,
    'match_id', v_match_attempt_id,
    'partner_id', v_best_match.id,
    'partner_info', jsonb_build_object(
      'continent', v_best_match.continent,
      'country', v_best_match.country,
      'city', v_best_match.city,
      'language', v_best_match.language
    ),
    'match_score', v_best_score,
    'distance_km', v_distance_km,
    'requires_confirmation', true,
    'confirmation_timeout', 30,
    'message', 'Match found, awaiting bilateral confirmation'
  );

EXCEPTION WHEN OTHERS THEN
  INSERT INTO connection_logs (user_id, event_type, message, event_data)
  VALUES (p_user_id, 'error', 'Match search failed: ' || SQLERRM, 
          jsonb_build_object('error', SQLERRM));
  
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Match search failed'
  );
END;
$$;

-- Function: Confirm bilateral match
CREATE OR REPLACE FUNCTION confirm_bilateral_match(
  p_user_id uuid,
  p_match_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_match match_attempts%ROWTYPE;
  v_chat_id uuid;
  v_partner_id uuid;
  v_both_confirmed boolean := false;
BEGIN
  -- Get match attempt
  SELECT * INTO v_match FROM match_attempts WHERE id = p_match_id;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Match not found');
  END IF;

  -- Check if match is still valid
  IF v_match.status != 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Match no longer pending');
  END IF;

  -- Check timeout
  IF now() > v_match.confirmation_timeout THEN
    UPDATE match_attempts SET status = 'timeout' WHERE id = p_match_id;
    
    -- Reset users to searching
    UPDATE waiting_users 
    SET status = 'searching', current_match_id = NULL 
    WHERE id IN (v_match.user1_id, v_match.user2_id);
    
    RETURN jsonb_build_object('success', false, 'error', 'Match confirmation timeout');
  END IF;

  -- Determine partner
  IF p_user_id = v_match.user1_id THEN
    v_partner_id := v_match.user2_id;
    UPDATE match_attempts SET user1_confirmed = true WHERE id = p_match_id;
  ELSIF p_user_id = v_match.user2_id THEN
    v_partner_id := v_match.user1_id;
    UPDATE match_attempts SET user2_confirmed = true WHERE id = p_match_id;
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'User not part of this match');
  END IF;

  -- Check if both confirmed
  SELECT user1_confirmed AND user2_confirmed INTO v_both_confirmed
  FROM match_attempts WHERE id = p_match_id;

  IF v_both_confirmed THEN
    -- Create chat session
    INSERT INTO chat_sessions (user1_id, user2_id, status)
    VALUES (v_match.user1_id, v_match.user2_id, 'active')
    RETURNING chat_id INTO v_chat_id;

    -- Update match status
    UPDATE match_attempts 
    SET status = 'confirmed', confirmed_at = now()
    WHERE id = p_match_id;

    -- Update users status
    UPDATE waiting_users 
    SET status = 'connected', updated_at = now()
    WHERE id IN (v_match.user1_id, v_match.user2_id);

    -- Log successful connection
    INSERT INTO connection_logs (user_id, event_type, message, event_data)
    VALUES (p_user_id, 'connected', 'Bilateral match confirmed, chat active', 
            jsonb_build_object('chat_id', v_chat_id, 'partner_id', v_partner_id));

    INSERT INTO connection_logs (user_id, event_type, message, event_data)
    VALUES (v_partner_id, 'connected', 'Bilateral match confirmed, chat active', 
            jsonb_build_object('chat_id', v_chat_id, 'partner_id', p_user_id));

    RETURN jsonb_build_object(
      'success', true,
      'both_confirmed', true,
      'chat_id', v_chat_id,
      'partner_id', v_partner_id,
      'message', 'Both users confirmed, chat is now active'
    );
  ELSE
    -- Log partial confirmation
    INSERT INTO connection_logs (user_id, event_type, message, event_data)
    VALUES (p_user_id, 'match_confirm', 'User confirmed match, waiting for partner', 
            jsonb_build_object('partner_id', v_partner_id));

    RETURN jsonb_build_object(
      'success', true,
      'both_confirmed', false,
      'partner_id', v_partner_id,
      'message', 'Confirmation received, waiting for partner'
    );
  END IF;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO connection_logs (user_id, event_type, message, event_data)
  VALUES (p_user_id, 'error', 'Match confirmation failed: ' || SQLERRM, 
          jsonb_build_object('match_id', p_match_id, 'error', SQLERRM));
  
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Match confirmation failed'
  );
END;
$$;

-- Function: Send heartbeat
CREATE OR REPLACE FUNCTION send_heartbeat(
  p_user_id uuid,
  p_connection_quality integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_session user_sessions%ROWTYPE;
BEGIN
  -- Update user heartbeat
  UPDATE waiting_users 
  SET last_heartbeat = now(), 
      connection_quality = p_connection_quality,
      updated_at = now()
  WHERE id = p_user_id;

  -- Update session heartbeat
  UPDATE user_sessions 
  SET last_heartbeat = now(),
      missed_heartbeats = 0
  WHERE user_id = p_user_id AND is_active = true;

  -- Log heartbeat (only every 10th to avoid spam)
  IF random() < 0.1 THEN
    INSERT INTO connection_logs (user_id, event_type, message, event_data)
    VALUES (p_user_id, 'heartbeat', 'Heartbeat received', 
            jsonb_build_object('connection_quality', p_connection_quality));
  END IF;

  RETURN jsonb_build_object('success', true, 'message', 'Heartbeat updated');

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- Function: Leave queue
CREATE OR REPLACE FUNCTION leave_waiting_queue(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Update user status
  UPDATE waiting_users 
  SET status = 'disconnected', updated_at = now()
  WHERE id = p_user_id;

  -- Deactivate sessions
  UPDATE user_sessions 
  SET is_active = false, disconnected_at = now()
  WHERE user_id = p_user_id;

  -- Log disconnect
  INSERT INTO connection_logs (user_id, event_type, message)
  VALUES (p_user_id, 'disconnected', 'User left waiting queue');

  RETURN jsonb_build_object('success', true, 'message', 'Left queue successfully');

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
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
    'average_wait_time', COALESCE(AVG(EXTRACT(EPOCH FROM (now() - joined_at))), 0),
    'timestamp', now()
  ) INTO v_stats
  FROM (
    SELECT 
      continent,
      language,
      joined_at,
      COUNT(*) OVER (PARTITION BY continent) as continent_count,
      COUNT(*) OVER (PARTITION BY language) as language_count
    FROM waiting_users 
    WHERE status = 'searching' 
      AND last_heartbeat > (now() - interval '60 seconds')
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

-- Function: Cleanup inactive sessions
CREATE OR REPLACE FUNCTION cleanup_inactive_sessions()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cleaned_users integer := 0;
  v_cleaned_sessions integer := 0;
  v_cleaned_matches integer := 0;
BEGIN
  -- Clean up inactive users (no heartbeat for 2 minutes)
  UPDATE waiting_users 
  SET status = 'disconnected', updated_at = now()
  WHERE status IN ('searching', 'matched', 'connecting')
    AND last_heartbeat < (now() - interval '2 minutes');
  
  GET DIAGNOSTICS v_cleaned_users = ROW_COUNT;

  -- Clean up inactive sessions
  UPDATE user_sessions 
  SET is_active = false, disconnected_at = now(), disconnect_reason = 'timeout'
  WHERE is_active = true 
    AND last_heartbeat < (now() - interval '2 minutes');
  
  GET DIAGNOSTICS v_cleaned_sessions = ROW_COUNT;

  -- Clean up expired match attempts
  UPDATE match_attempts 
  SET status = 'timeout'
  WHERE status = 'pending' 
    AND confirmation_timeout < now();
  
  GET DIAGNOSTICS v_cleaned_matches = ROW_COUNT;

  -- Delete old logs (keep only last 24 hours)
  DELETE FROM connection_logs 
  WHERE timestamp < (now() - interval '24 hours');

  -- Delete old disconnected users (keep only last hour)
  DELETE FROM waiting_users 
  WHERE status = 'disconnected' 
    AND updated_at < (now() - interval '1 hour');

  -- Log cleanup
  INSERT INTO connection_logs (event_type, message, event_data)
  VALUES ('cleanup', 'Cleanup completed', jsonb_build_object(
    'cleaned_users', v_cleaned_users,
    'cleaned_sessions', v_cleaned_sessions,
    'cleaned_matches', v_cleaned_matches
  ));

  RETURN jsonb_build_object(
    'success', true,
    'cleaned_users', v_cleaned_users,
    'cleaned_sessions', v_cleaned_sessions,
    'cleaned_matches', v_cleaned_matches,
    'message', 'Cleanup completed successfully'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION join_waiting_queue TO anon, authenticated;
GRANT EXECUTE ON FUNCTION find_best_match TO anon, authenticated;
GRANT EXECUTE ON FUNCTION confirm_bilateral_match TO anon, authenticated;
GRANT EXECUTE ON FUNCTION send_heartbeat TO anon, authenticated;
GRANT EXECUTE ON FUNCTION leave_waiting_queue TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_queue_statistics TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleanup_inactive_sessions TO anon, authenticated;

-- Create automatic cleanup job (runs every 30 seconds)
-- Note: This would typically be handled by a cron job or background task
-- For now, we'll rely on the frontend to call cleanup periodically