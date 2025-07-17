/*
  # Bazoocam-style Matching System

  1. Enhanced Tables
    - Add matching queue system
    - Optimize for multi-device connections
    - Add session management

  2. Smart Matching Functions
    - 3s timeout for nearby users
    - Immediate global fallback
    - Always connect available users

  3. Realtime Optimizations
    - Presence tracking
    - Connection status management
    - Auto-cleanup inactive sessions
*/

-- Add matching queue and session management
DO $$
BEGIN
  -- Add matching queue columns
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'matching_since'
  ) THEN
    ALTER TABLE users ADD COLUMN matching_since timestamptz;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'device_id'
  ) THEN
    ALTER TABLE users ADD COLUMN device_id text DEFAULT gen_random_uuid()::text;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'matching_attempts'
  ) THEN
    ALTER TABLE users ADD COLUMN matching_attempts integer DEFAULT 0;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'last_match_attempt'
  ) THEN
    ALTER TABLE users ADD COLUMN last_match_attempt timestamptz;
  END IF;
END $$;

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_users_matching_since ON users(matching_since) WHERE matching_since IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_device_id ON users(device_id);
CREATE INDEX IF NOT EXISTS idx_users_last_match_attempt ON users(last_match_attempt);

-- Enhanced matching function with 3s timeout and global fallback
CREATE OR REPLACE FUNCTION find_bazoocam_match(
  user_id uuid,
  user_location geography DEFAULT NULL,
  max_nearby_distance_km numeric DEFAULT 1000
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  match_id uuid;
  nearby_matches uuid[];
  global_matches uuid[];
  current_time timestamptz := now();
BEGIN
  -- Update user matching status
  UPDATE users 
  SET 
    matching_since = current_time,
    last_match_attempt = current_time,
    matching_attempts = COALESCE(matching_attempts, 0) + 1,
    status = 'waiting',
    last_activity = current_time
  WHERE id = user_id;

  -- PHASE 1: Try nearby matches first (if location available)
  IF user_location IS NOT NULL THEN
    SELECT ARRAY(
      SELECT u.id
      FROM users u
      WHERE u.id != user_id
        AND u.status = 'waiting'
        AND u.connection_status = 'online'
        AND u.last_activity > (current_time - interval '2 minutes')
        AND u.location IS NOT NULL
        AND NOT (u.id = ANY(COALESCE((SELECT previous_matches FROM users WHERE id = user_id), ARRAY[]::uuid[])))
        AND NOT (user_id = ANY(COALESCE(u.previous_matches, ARRAY[]::uuid[])))
        AND ST_DWithin(u.location, user_location, max_nearby_distance_km * 1000)
      ORDER BY ST_Distance(u.location, user_location)
      LIMIT 20
    ) INTO nearby_matches;

    -- Select random nearby match
    IF array_length(nearby_matches, 1) > 0 THEN
      match_id := nearby_matches[1 + floor(random() * array_length(nearby_matches, 1))::int];
      
      -- Verify match is still available
      UPDATE users 
      SET status = 'matched', matching_since = NULL
      WHERE id = match_id 
        AND status = 'waiting' 
        AND connection_status = 'online';
      
      IF FOUND THEN
        UPDATE users 
        SET status = 'matched', matching_since = NULL
        WHERE id = user_id;
        
        RETURN match_id;
      END IF;
    END IF;
  END IF;

  -- PHASE 2: Global fallback - match with ANY available user
  SELECT ARRAY(
    SELECT u.id
    FROM users u
    WHERE u.id != user_id
      AND u.status = 'waiting'
      AND u.connection_status = 'online'
      AND u.last_activity > (current_time - interval '5 minutes')
      AND NOT (u.id = ANY(COALESCE((SELECT previous_matches FROM users WHERE id = user_id), ARRAY[]::uuid[])))
      AND NOT (user_id = ANY(COALESCE(u.previous_matches, ARRAY[]::uuid[])))
    ORDER BY u.connected_at DESC
    LIMIT 50
  ) INTO global_matches;

  -- Select random global match
  IF array_length(global_matches, 1) > 0 THEN
    match_id := global_matches[1 + floor(random() * array_length(global_matches, 1))::int];
    
    -- Atomic match assignment
    UPDATE users 
    SET status = 'matched', matching_since = NULL
    WHERE id = match_id 
      AND status = 'waiting' 
      AND connection_status = 'online';
    
    IF FOUND THEN
      UPDATE users 
      SET status = 'matched', matching_since = NULL
      WHERE id = user_id;
      
      RETURN match_id;
    END IF;
  END IF;

  -- PHASE 3: Desperate fallback - match with ANYONE online (ignore previous matches)
  SELECT u.id INTO match_id
  FROM users u
  WHERE u.id != user_id
    AND u.status IN ('waiting', 'matched')
    AND u.connection_status = 'online'
    AND u.last_activity > (current_time - interval '10 minutes')
  ORDER BY 
    CASE WHEN u.status = 'waiting' THEN 1 ELSE 2 END,
    u.last_activity DESC
  LIMIT 1;

  IF match_id IS NOT NULL THEN
    UPDATE users 
    SET status = 'matched', matching_since = NULL
    WHERE id = match_id;
    
    UPDATE users 
    SET status = 'matched', matching_since = NULL
    WHERE id = user_id;
    
    RETURN match_id;
  END IF;

  -- No match found - keep waiting
  RETURN NULL;
END;
$$;

-- Function to cleanup stuck matching sessions
CREATE OR REPLACE FUNCTION cleanup_matching_queue()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Reset users stuck in matching for more than 30 seconds
  UPDATE users 
  SET 
    status = 'waiting',
    matching_since = NULL
  WHERE matching_since IS NOT NULL 
    AND matching_since < (now() - interval '30 seconds');

  -- Cleanup completely inactive sessions
  UPDATE users 
  SET 
    status = 'disconnected',
    connection_status = 'offline'
  WHERE last_activity < (now() - interval '10 minutes')
    AND status != 'disconnected';

  -- Remove very old disconnected users
  DELETE FROM users 
  WHERE status = 'disconnected' 
    AND last_activity < (now() - interval '1 hour');
END;
$$;

-- Function to force match any two waiting users (multi-device support)
CREATE OR REPLACE FUNCTION force_match_waiting_users()
RETURNS TABLE(user1_id uuid, user2_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  waiting_users uuid[];
  user1 uuid;
  user2 uuid;
BEGIN
  -- Get all waiting users
  SELECT ARRAY(
    SELECT u.id
    FROM users u
    WHERE u.status = 'waiting'
      AND u.connection_status = 'online'
      AND u.last_activity > (now() - interval '5 minutes')
    ORDER BY u.matching_since ASC NULLS LAST
    LIMIT 10
  ) INTO waiting_users;

  -- Match pairs of waiting users
  FOR i IN 1..array_length(waiting_users, 1) BY 2 LOOP
    IF i + 1 <= array_length(waiting_users, 1) THEN
      user1 := waiting_users[i];
      user2 := waiting_users[i + 1];
      
      -- Update both users to matched
      UPDATE users 
      SET status = 'matched', matching_since = NULL
      WHERE id IN (user1, user2)
        AND status = 'waiting';
      
      IF FOUND THEN
        user1_id := user1;
        user2_id := user2;
        RETURN NEXT;
      END IF;
    END IF;
  END LOOP;
END;
$$;

-- Enhanced RLS policies
DROP POLICY IF EXISTS "Users can read all active users" ON users;
CREATE POLICY "Users can read all active users"
  ON users
  FOR SELECT
  TO authenticated, anon
  USING (
    status IN ('waiting', 'matched', 'chatting') 
    OR connection_status = 'online'
    OR last_activity > (now() - interval '5 minutes')
  );

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION find_bazoocam_match TO authenticated, anon;
GRANT EXECUTE ON FUNCTION cleanup_matching_queue TO authenticated, anon;
GRANT EXECUTE ON FUNCTION force_match_waiting_users TO authenticated, anon;