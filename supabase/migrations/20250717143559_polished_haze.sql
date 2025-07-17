/*
  # Fix database schema and frequent errors

  1. Schema Updates
    - Fix waiting_users table structure
    - Add missing columns and constraints
    - Update RPC functions for better error handling
    - Add proper indexes for performance

  2. Error Fixes
    - Fix device_id handling
    - Improve session management
    - Better error handling in RPC functions
    - Add proper cleanup procedures

  3. Performance Improvements
    - Add missing indexes
    - Optimize RPC functions
    - Better connection handling
*/

-- Drop existing problematic functions first
DROP FUNCTION IF EXISTS join_waiting_queue_v2(text, text, text, text, text, double precision, double precision, text, inet);
DROP FUNCTION IF EXISTS send_heartbeat_v2(uuid, integer);
DROP FUNCTION IF EXISTS find_best_match_v2(uuid);
DROP FUNCTION IF EXISTS confirm_bilateral_match_v2(uuid, uuid);
DROP FUNCTION IF EXISTS cleanup_inactive_sessions_v2();
DROP FUNCTION IF EXISTS get_queue_statistics_v2();

-- Update waiting_users table structure
ALTER TABLE waiting_users 
DROP CONSTRAINT IF EXISTS waiting_users_device_id_key;

-- Add device_id as primary key if not exists
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'waiting_users' AND column_name = 'device_id' AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE waiting_users ALTER COLUMN device_id SET NOT NULL;
  END IF;
END $$;

-- Recreate unique constraint on device_id
ALTER TABLE waiting_users ADD CONSTRAINT waiting_users_device_id_key UNIQUE (device_id);

-- Add missing columns if they don't exist
DO $$
BEGIN
  -- Add previous_matches column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'waiting_users' AND column_name = 'previous_matches'
  ) THEN
    ALTER TABLE waiting_users ADD COLUMN previous_matches text[] DEFAULT '{}';
  END IF;

  -- Add is_active column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'waiting_users' AND column_name = 'is_active'
  ) THEN
    ALTER TABLE waiting_users ADD COLUMN is_active boolean DEFAULT true;
  END IF;

  -- Add session_active column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'waiting_users' AND column_name = 'session_active'
  ) THEN
    ALTER TABLE waiting_users ADD COLUMN session_active boolean DEFAULT true;
  END IF;
END $$;

-- Update indexes for better performance
CREATE INDEX IF NOT EXISTS idx_waiting_users_device_id ON waiting_users(device_id);
CREATE INDEX IF NOT EXISTS idx_waiting_users_active ON waiting_users(is_active, session_active);
CREATE INDEX IF NOT EXISTS idx_waiting_users_search ON waiting_users(status, continent, language) WHERE is_active = true;

-- Improved join_waiting_queue_v2 function
CREATE OR REPLACE FUNCTION join_waiting_queue_v2(
  p_device_id text,
  p_continent text DEFAULT 'Unknown',
  p_country text DEFAULT 'Unknown',
  p_city text DEFAULT 'Unknown',
  p_language text DEFAULT 'en',
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_ip_address inet DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_user_id uuid;
  v_session_id uuid;
  v_queue_position integer;
  v_estimated_wait integer;
  v_location geography;
BEGIN
  -- Generate UUIDs
  v_user_id := gen_random_uuid();
  v_session_id := gen_random_uuid();
  
  -- Create location point if coordinates provided
  IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
    v_location := ST_Point(p_longitude, p_latitude)::geography;
  END IF;

  -- Insert or update user in waiting queue
  INSERT INTO waiting_users (
    id,
    device_id,
    session_token,
    location,
    continent,
    country,
    city,
    language,
    status,
    joined_at,
    last_heartbeat,
    is_active,
    session_active,
    user_agent,
    ip_address,
    created_at,
    updated_at
  ) VALUES (
    v_user_id,
    p_device_id,
    v_session_id::text,
    v_location,
    COALESCE(p_continent, 'Unknown'),
    COALESCE(p_country, 'Unknown'),
    COALESCE(p_city, 'Unknown'),
    COALESCE(p_language, 'en'),
    'searching',
    now(),
    now(),
    true,
    true,
    p_user_agent,
    p_ip_address,
    now(),
    now()
  ) ON CONFLICT (device_id) DO UPDATE SET
    session_token = v_session_id::text,
    location = v_location,
    continent = COALESCE(p_continent, 'Unknown'),
    country = COALESCE(p_country, 'Unknown'),
    city = COALESCE(p_city, 'Unknown'),
    language = COALESCE(p_language, 'en'),
    status = 'searching',
    joined_at = now(),
    last_heartbeat = now(),
    is_active = true,
    session_active = true,
    user_agent = p_user_agent,
    ip_address = p_ip_address,
    updated_at = now()
  RETURNING id INTO v_user_id;

  -- Calculate queue position
  SELECT COUNT(*) INTO v_queue_position
  FROM waiting_users 
  WHERE status = 'searching' 
    AND is_active = true 
    AND session_active = true
    AND joined_at < (SELECT joined_at FROM waiting_users WHERE id = v_user_id);

  -- Estimate wait time (rough calculation)
  v_estimated_wait := GREATEST(v_queue_position * 5, 10);

  -- Insert session record
  INSERT INTO user_sessions (
    user_id,
    session_token,
    connected_at,
    last_heartbeat,
    is_active
  ) VALUES (
    v_user_id,
    v_session_id::text,
    now(),
    now(),
    true
  ) ON CONFLICT (session_token) DO UPDATE SET
    last_heartbeat = now(),
    is_active = true;

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'session_id', v_session_id,
    'queue_position', v_queue_position,
    'estimated_wait_seconds', v_estimated_wait,
    'message', 'Successfully joined waiting queue'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Failed to join waiting queue'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Improved send_heartbeat_v2 function
CREATE OR REPLACE FUNCTION send_heartbeat_v2(
  p_user_id uuid,
  p_connection_quality integer DEFAULT 100
) RETURNS jsonb AS $$
BEGIN
  -- Update user heartbeat
  UPDATE waiting_users 
  SET 
    last_heartbeat = now(),
    connection_quality = p_connection_quality,
    updated_at = now()
  WHERE id = p_user_id AND is_active = true;

  -- Update session heartbeat
  UPDATE user_sessions 
  SET 
    last_heartbeat = now(),
    missed_heartbeats = 0
  WHERE user_id = p_user_id AND is_active = true;

  RETURN jsonb_build_object(
    'success', true,
    'timestamp', now(),
    'message', 'Heartbeat updated successfully'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Failed to update heartbeat'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Improved find_best_match_v2 function
CREATE OR REPLACE FUNCTION find_best_match_v2(
  p_user_id uuid
) RETURNS jsonb AS $$
DECLARE
  v_user_record waiting_users%ROWTYPE;
  v_potential_match waiting_users%ROWTYPE;
  v_match_id uuid;
  v_distance_km integer;
  v_match_score integer;
BEGIN
  -- Get current user info
  SELECT * INTO v_user_record
  FROM waiting_users 
  WHERE id = p_user_id AND is_active = true AND session_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not found or inactive',
      'message', 'User not in active queue'
    );
  END IF;

  -- Find best match with preference for same continent/language
  SELECT * INTO v_potential_match
  FROM waiting_users w
  WHERE w.id != p_user_id
    AND w.status = 'searching'
    AND w.is_active = true
    AND w.session_active = true
    AND w.last_heartbeat > now() - interval '30 seconds'
    AND NOT (w.id = ANY(v_user_record.previous_matches))
  ORDER BY 
    -- Prioritize same continent and language
    CASE WHEN w.continent = v_user_record.continent AND w.language = v_user_record.language THEN 1
         WHEN w.continent = v_user_record.continent THEN 2
         WHEN w.language = v_user_record.language THEN 3
         ELSE 4 END,
    -- Then by connection quality
    w.connection_quality DESC,
    -- Then by wait time (oldest first)
    w.joined_at ASC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'total_waiting', (SELECT COUNT(*) FROM waiting_users WHERE status = 'searching' AND is_active = true),
      'message', 'No suitable match found'
    );
  END IF;

  -- Calculate match score and distance
  v_match_score := 100;
  IF v_potential_match.continent = v_user_record.continent THEN
    v_match_score := v_match_score + 20;
  END IF;
  IF v_potential_match.language = v_user_record.language THEN
    v_match_score := v_match_score + 30;
  END IF;

  -- Calculate distance if both have location
  IF v_user_record.location IS NOT NULL AND v_potential_match.location IS NOT NULL THEN
    v_distance_km := ST_Distance(v_user_record.location, v_potential_match.location) / 1000;
    IF v_distance_km < 100 THEN
      v_match_score := v_match_score + 25;
    ELSIF v_distance_km < 500 THEN
      v_match_score := v_match_score + 15;
    END IF;
  END IF;

  -- Create match attempt
  v_match_id := gen_random_uuid();
  
  INSERT INTO match_attempts (
    id,
    user1_id,
    user2_id,
    match_score,
    distance_km,
    language_match,
    continent_match,
    status,
    created_at
  ) VALUES (
    v_match_id,
    p_user_id,
    v_potential_match.id,
    v_match_score,
    v_distance_km,
    v_potential_match.language = v_user_record.language,
    v_potential_match.continent = v_user_record.continent,
    'pending',
    now()
  );

  -- Update both users status
  UPDATE waiting_users 
  SET 
    status = 'matched',
    current_match_id = v_match_id,
    updated_at = now()
  WHERE id IN (p_user_id, v_potential_match.id);

  RETURN jsonb_build_object(
    'success', true,
    'match_id', v_match_id,
    'partner_id', v_potential_match.id,
    'match_score', v_match_score,
    'distance_km', v_distance_km,
    'requires_confirmation', true,
    'partner_info', jsonb_build_object(
      'continent', v_potential_match.continent,
      'country', v_potential_match.country,
      'city', v_potential_match.city,
      'language', v_potential_match.language
    ),
    'message', 'Match found, awaiting confirmation'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Error finding match'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Improved confirm_bilateral_match_v2 function
CREATE OR REPLACE FUNCTION confirm_bilateral_match_v2(
  p_user_id uuid,
  p_match_id uuid
) RETURNS jsonb AS $$
DECLARE
  v_match_record match_attempts%ROWTYPE;
  v_chat_id uuid;
  v_partner_id uuid;
  v_both_confirmed boolean := false;
BEGIN
  -- Get match record
  SELECT * INTO v_match_record
  FROM match_attempts 
  WHERE id = p_match_id 
    AND (user1_id = p_user_id OR user2_id = p_user_id)
    AND status = 'pending';

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Match not found or expired',
      'message', 'Invalid match ID'
    );
  END IF;

  -- Determine partner ID
  IF v_match_record.user1_id = p_user_id THEN
    v_partner_id := v_match_record.user2_id;
  ELSE
    v_partner_id := v_match_record.user1_id;
  END IF;

  -- Update confirmation status
  IF v_match_record.user1_id = p_user_id THEN
    UPDATE match_attempts 
    SET user1_confirmed = true, updated_at = now()
    WHERE id = p_match_id;
  ELSE
    UPDATE match_attempts 
    SET user2_confirmed = true, updated_at = now()
    WHERE id = p_match_id;
  END IF;

  -- Check if both confirmed
  SELECT user1_confirmed AND user2_confirmed INTO v_both_confirmed
  FROM match_attempts 
  WHERE id = p_match_id;

  IF v_both_confirmed THEN
    -- Create chat session
    v_chat_id := gen_random_uuid();
    
    INSERT INTO chat_sessions (
      chat_id,
      user1_id,
      user2_id,
      status,
      created_at,
      user1_confirmed,
      user2_confirmed
    ) VALUES (
      v_chat_id,
      v_match_record.user1_id,
      v_match_record.user2_id,
      'active',
      now(),
      true,
      true
    );

    -- Update match status
    UPDATE match_attempts 
    SET 
      status = 'confirmed',
      confirmed_at = now()
    WHERE id = p_match_id;

    -- Update users status
    UPDATE waiting_users 
    SET 
      status = 'connected',
      updated_at = now()
    WHERE id IN (v_match_record.user1_id, v_match_record.user2_id);

    RETURN jsonb_build_object(
      'success', true,
      'both_confirmed', true,
      'chat_id', v_chat_id,
      'partner_id', v_partner_id,
      'message', 'Match confirmed, chat active'
    );
  ELSE
    RETURN jsonb_build_object(
      'success', true,
      'both_confirmed', false,
      'message', 'Waiting for partner confirmation'
    );
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Error confirming match'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Improved cleanup function
CREATE OR REPLACE FUNCTION cleanup_inactive_sessions_v2()
RETURNS jsonb AS $$
DECLARE
  v_cleaned_users integer := 0;
  v_cleaned_sessions integer := 0;
  v_cleaned_matches integer := 0;
BEGIN
  -- Clean up inactive users (no heartbeat for 60 seconds)
  UPDATE waiting_users 
  SET 
    is_active = false,
    session_active = false,
    status = 'disconnected',
    updated_at = now()
  WHERE last_heartbeat < now() - interval '60 seconds'
    AND is_active = true;
  
  GET DIAGNOSTICS v_cleaned_users = ROW_COUNT;

  -- Clean up inactive sessions
  UPDATE user_sessions 
  SET 
    is_active = false,
    disconnect_reason = 'timeout',
    disconnected_at = now()
  WHERE last_heartbeat < now() - interval '60 seconds'
    AND is_active = true;
  
  GET DIAGNOSTICS v_cleaned_sessions = ROW_COUNT;

  -- Clean up expired match attempts (older than 2 minutes)
  UPDATE match_attempts 
  SET status = 'timeout'
  WHERE created_at < now() - interval '2 minutes'
    AND status = 'pending';
  
  GET DIAGNOSTICS v_cleaned_matches = ROW_COUNT;

  -- End chat sessions where one user is inactive
  UPDATE chat_sessions 
  SET 
    status = 'ended',
    ended_at = now()
  WHERE status = 'active'
    AND (
      user1_id IN (SELECT id FROM waiting_users WHERE is_active = false)
      OR user2_id IN (SELECT id FROM waiting_users WHERE is_active = false)
    );

  RETURN jsonb_build_object(
    'success', true,
    'cleaned_users', v_cleaned_users,
    'cleaned_sessions', v_cleaned_sessions,
    'cleaned_matches', v_cleaned_matches,
    'timestamp', now()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Cleanup failed'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Improved queue statistics function
CREATE OR REPLACE FUNCTION get_queue_statistics_v2()
RETURNS jsonb AS $$
DECLARE
  v_total_waiting integer;
  v_by_continent jsonb;
  v_by_language jsonb;
  v_avg_wait_time integer;
BEGIN
  -- Get total waiting users
  SELECT COUNT(*) INTO v_total_waiting
  FROM waiting_users 
  WHERE status = 'searching' 
    AND is_active = true 
    AND session_active = true;

  -- Get distribution by continent
  SELECT jsonb_object_agg(continent, count)
  INTO v_by_continent
  FROM (
    SELECT continent, COUNT(*) as count
    FROM waiting_users 
    WHERE status = 'searching' 
      AND is_active = true 
      AND session_active = true
    GROUP BY continent
  ) t;

  -- Get distribution by language
  SELECT jsonb_object_agg(language, count)
  INTO v_by_language
  FROM (
    SELECT language, COUNT(*) as count
    FROM waiting_users 
    WHERE status = 'searching' 
      AND is_active = true 
      AND session_active = true
    GROUP BY language
  ) t;

  -- Calculate average wait time
  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (now() - joined_at))), 0)::integer
  INTO v_avg_wait_time
  FROM waiting_users 
  WHERE status = 'searching' 
    AND is_active = true 
    AND session_active = true;

  RETURN jsonb_build_object(
    'total_waiting', v_total_waiting,
    'by_continent', COALESCE(v_by_continent, '{}'::jsonb),
    'by_language', COALESCE(v_by_language, '{}'::jsonb),
    'average_wait_time', v_avg_wait_time,
    'timestamp', now()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'total_waiting', 0,
    'by_continent', '{}'::jsonb,
    'by_language', '{}'::jsonb,
    'average_wait_time', 0,
    'error', SQLERRM
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Add leave_waiting_queue_v2 function
CREATE OR REPLACE FUNCTION leave_waiting_queue_v2(
  p_user_id uuid
) RETURNS jsonb AS $$
BEGIN
  -- Update user status
  UPDATE waiting_users 
  SET 
    status = 'disconnected',
    is_active = false,
    session_active = false,
    updated_at = now()
  WHERE id = p_user_id;

  -- Update session status
  UPDATE user_sessions 
  SET 
    is_active = false,
    disconnect_reason = 'user_left',
    disconnected_at = now()
  WHERE user_id = p_user_id;

  -- Cancel any pending matches
  UPDATE match_attempts 
  SET status = 'rejected'
  WHERE (user1_id = p_user_id OR user2_id = p_user_id)
    AND status = 'pending';

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Successfully left waiting queue'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Failed to leave queue'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Add check_user_status function
CREATE OR REPLACE FUNCTION check_user_status(
  p_user_id uuid
) RETURNS jsonb AS $$
DECLARE
  v_user_active boolean := false;
BEGIN
  SELECT is_active AND session_active INTO v_user_active
  FROM waiting_users 
  WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'is_active', COALESCE(v_user_active, false),
    'timestamp', now()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'is_active', false,
    'error', SQLERRM
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Add end_chat_session function
CREATE OR REPLACE FUNCTION end_chat_session(
  p_user_id uuid,
  p_chat_id uuid
) RETURNS jsonb AS $$
BEGIN
  -- End the chat session
  UPDATE chat_sessions 
  SET 
    status = 'ended',
    ended_at = now()
  WHERE chat_id = p_chat_id
    AND (user1_id = p_user_id OR user2_id = p_user_id);

  -- Update user status back to searching or disconnected
  UPDATE waiting_users 
  SET 
    status = 'disconnected',
    current_match_id = NULL,
    updated_at = now()
  WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Chat session ended'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'message', 'Failed to end chat session'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION join_waiting_queue_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION send_heartbeat_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION find_best_match_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION confirm_bilateral_match_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleanup_inactive_sessions_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_queue_statistics_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION leave_waiting_queue_v2 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION check_user_status TO anon, authenticated;
GRANT EXECUTE ON FUNCTION end_chat_session TO anon, authenticated;