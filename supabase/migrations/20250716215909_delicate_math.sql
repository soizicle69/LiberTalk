/*
  # Fix missing location column and optimize database structure

  1. Database Structure
    - Add missing `location` column (geography Point)
    - Add `previous_matches` array for avoiding repeats
    - Add `last_seen`, `connection_status` for presence tracking
    - Add proper indexes for performance

  2. Functions
    - Create optimized matching function with geographic priority
    - Add presence tracking and cleanup functions
    - Handle all edge cases and fallbacks

  3. Security
    - Update RLS policies for new columns
    - Ensure proper access control for realtime features
*/

-- First, ensure all required columns exist
DO $$
BEGIN
  -- Add location column if it doesn't exist
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'location'
  ) THEN
    ALTER TABLE users ADD COLUMN location geography(Point, 4326);
  END IF;

  -- Add previous_matches column if it doesn't exist
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'previous_matches'
  ) THEN
    ALTER TABLE users ADD COLUMN previous_matches uuid[] DEFAULT ARRAY[]::uuid[];
  END IF;

  -- Add last_seen column if it doesn't exist
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'last_seen'
  ) THEN
    ALTER TABLE users ADD COLUMN last_seen timestamptz DEFAULT now();
  END IF;

  -- Add connection_status column if it doesn't exist
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'connection_status'
  ) THEN
    ALTER TABLE users ADD COLUMN connection_status text DEFAULT 'online' CHECK (connection_status IN ('online', 'offline', 'away'));
  END IF;
END $$;

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_users_location ON users USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_users_last_seen ON users (last_seen);
CREATE INDEX IF NOT EXISTS idx_users_connection_status ON users (connection_status);
CREATE INDEX IF NOT EXISTS idx_users_status_connected ON users (status, connected_at) WHERE status IN ('waiting', 'matched');

-- Drop existing functions to avoid conflicts
DROP FUNCTION IF EXISTS find_nearest_match(uuid, geography, integer);
DROP FUNCTION IF EXISTS update_user_location(uuid, double precision, double precision);
DROP FUNCTION IF EXISTS cleanup_inactive_users();
DROP FUNCTION IF EXISTS update_user_presence(uuid, text);

-- Create optimized matching function
CREATE OR REPLACE FUNCTION find_nearest_match(
  user_id uuid,
  user_location geography DEFAULT NULL,
  max_distance_km integer DEFAULT 1000
) RETURNS uuid AS $$
DECLARE
  match_id uuid;
  fallback_match_id uuid;
BEGIN
  -- Update user's last activity
  UPDATE users 
  SET last_activity = now(), last_seen = now(), connection_status = 'online'
  WHERE id = user_id;

  -- First try: Geographic matching with distance priority
  IF user_location IS NOT NULL THEN
    WITH nearby_users AS (
      SELECT 
        u.id,
        ST_Distance(u.location, user_location) as distance
      FROM users u
      WHERE u.id != user_id
        AND u.status = 'waiting'
        AND u.connection_status = 'online'
        AND u.connected_at > now() - interval '5 minutes'
        AND u.last_activity > now() - interval '2 minutes'
        AND u.location IS NOT NULL
        AND (u.id != ALL(COALESCE((SELECT previous_matches FROM users WHERE id = user_id), ARRAY[]::uuid[])))
        AND (user_id != ALL(COALESCE(u.previous_matches, ARRAY[]::uuid[])))
        AND ST_DWithin(u.location, user_location, max_distance_km * 1000)
      ORDER BY distance ASC
      LIMIT 10
    )
    SELECT id INTO match_id
    FROM nearby_users
    ORDER BY RANDOM()
    LIMIT 1;
  END IF;

  -- Second try: Same continent/region without strict distance
  IF match_id IS NULL AND user_location IS NOT NULL THEN
    WITH regional_users AS (
      SELECT u.id
      FROM users u
      WHERE u.id != user_id
        AND u.status = 'waiting'
        AND u.connection_status = 'online'
        AND u.connected_at > now() - interval '10 minutes'
        AND u.last_activity > now() - interval '5 minutes'
        AND u.continent = (SELECT continent FROM users WHERE id = user_id)
        AND (u.id != ALL(COALESCE((SELECT previous_matches FROM users WHERE id = user_id), ARRAY[]::uuid[])))
        AND (user_id != ALL(COALESCE(u.previous_matches, ARRAY[]::uuid[])))
      ORDER BY u.connected_at DESC
      LIMIT 15
    )
    SELECT id INTO match_id
    FROM regional_users
    ORDER BY RANDOM()
    LIMIT 1;
  END IF;

  -- Third try: Global random matching (fallback)
  IF match_id IS NULL THEN
    WITH global_users AS (
      SELECT u.id
      FROM users u
      WHERE u.id != user_id
        AND u.status = 'waiting'
        AND u.connection_status = 'online'
        AND u.connected_at > now() - interval '15 minutes'
        AND u.last_activity > now() - interval '10 minutes'
        AND (u.id != ALL(COALESCE((SELECT previous_matches FROM users WHERE id = user_id), ARRAY[]::uuid[])))
        AND (user_id != ALL(COALESCE(u.previous_matches, ARRAY[]::uuid[])))
      ORDER BY u.connected_at DESC
      LIMIT 20
    )
    SELECT id INTO match_id
    FROM global_users
    ORDER BY RANDOM()
    LIMIT 1;
  END IF;

  -- Last resort: Any available user (ignore previous matches)
  IF match_id IS NULL THEN
    SELECT u.id INTO fallback_match_id
    FROM users u
    WHERE u.id != user_id
      AND u.status = 'waiting'
      AND u.connection_status = 'online'
      AND u.connected_at > now() - interval '30 minutes'
    ORDER BY RANDOM()
    LIMIT 1;
    
    match_id := fallback_match_id;
  END IF;

  RETURN match_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to update user location
CREATE OR REPLACE FUNCTION update_user_location(
  user_id uuid,
  latitude double precision,
  longitude double precision
) RETURNS void AS $$
BEGIN
  UPDATE users 
  SET 
    location = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326),
    last_activity = now(),
    last_seen = now()
  WHERE id = user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to update user presence
CREATE OR REPLACE FUNCTION update_user_presence(
  user_id uuid,
  status text DEFAULT 'online'
) RETURNS void AS $$
BEGIN
  UPDATE users 
  SET 
    connection_status = status,
    last_seen = now(),
    last_activity = CASE WHEN status = 'online' THEN now() ELSE last_activity END
  WHERE id = user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to cleanup inactive users and sessions
CREATE OR REPLACE FUNCTION cleanup_inactive_users() RETURNS void AS $$
BEGIN
  -- Mark users as offline if inactive for more than 2 minutes
  UPDATE users 
  SET connection_status = 'offline'
  WHERE connection_status = 'online' 
    AND last_seen < now() - interval '2 minutes';

  -- Disconnect users inactive for more than 5 minutes
  UPDATE users 
  SET status = 'disconnected'
  WHERE status IN ('waiting', 'matched', 'chatting')
    AND last_activity < now() - interval '5 minutes';

  -- End chats where users are disconnected
  UPDATE chats 
  SET status = 'ended', ended_at = now()
  WHERE status = 'active'
    AND (
      user1_id IN (SELECT id FROM users WHERE status = 'disconnected') OR
      user2_id IN (SELECT id FROM users WHERE status = 'disconnected')
    );

  -- Delete very old disconnected users (older than 1 hour)
  DELETE FROM users 
  WHERE status = 'disconnected' 
    AND last_activity < now() - interval '1 hour';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update RLS policies for new columns
DROP POLICY IF EXISTS "Users can read all active users" ON users;
CREATE POLICY "Users can read all active users" ON users
  FOR SELECT TO anon, authenticated
  USING (
    status = ANY(ARRAY['waiting'::text, 'matched'::text, 'chatting'::text]) OR
    connection_status = 'online'
  );

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION find_nearest_match(uuid, geography, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION update_user_location(uuid, double precision, double precision) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION update_user_presence(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleanup_inactive_users() TO anon, authenticated;