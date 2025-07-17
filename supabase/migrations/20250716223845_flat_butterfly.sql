/*
# Fix RPC Functions for Waiting Queue

This migration creates the missing RPC functions that the frontend is calling.

## Functions Created
1. add_to_waiting_queue - Adds user to matching queue
2. remove_from_waiting_queue - Removes user from queue
3. match_user - Matches users for chat
4. cleanup_waiting_queue - Removes stale entries
5. get_queue_stats - Returns queue statistics

## Security
- All functions use SECURITY DEFINER
- Proper RLS policies applied
- Explicit permissions granted
*/

-- Create waiting_users table if it doesn't exist
CREATE TABLE IF NOT EXISTS waiting_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  latitude double precision,
  longitude double precision,
  location geography(Point, 4326),
  previous_matches uuid[] DEFAULT ARRAY[]::uuid[],
  language text DEFAULT 'en',
  continent text DEFAULT 'Unknown',
  joined_at timestamptz DEFAULT now(),
  retry_count integer DEFAULT 0,
  last_attempt timestamptz DEFAULT now()
);

-- Enable RLS
ALTER TABLE waiting_users ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "Users can manage waiting queue" ON waiting_users;

-- Create RLS policy
CREATE POLICY "Users can manage waiting queue" ON waiting_users
  FOR ALL
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_waiting_users_user_id ON waiting_users(user_id);
CREATE INDEX IF NOT EXISTS idx_waiting_users_continent ON waiting_users(continent);
CREATE INDEX IF NOT EXISTS idx_waiting_users_joined_at ON waiting_users(joined_at);
CREATE INDEX IF NOT EXISTS idx_waiting_users_location ON waiting_users USING GIST(location);

-- Function 1: Add to waiting queue
CREATE OR REPLACE FUNCTION add_to_waiting_queue(
  p_user_id uuid,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_previous_matches uuid[] DEFAULT ARRAY[]::uuid[],
  p_language text DEFAULT 'en',
  p_continent text DEFAULT 'Unknown'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_queue_id uuid;
  v_location geography(Point, 4326);
BEGIN
  -- Create location point if coordinates provided
  IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography;
  END IF;

  -- Insert or update user in waiting queue
  INSERT INTO waiting_users (
    user_id, 
    latitude, 
    longitude, 
    location,
    previous_matches, 
    language, 
    continent,
    joined_at,
    retry_count,
    last_attempt
  ) VALUES (
    p_user_id,
    p_latitude,
    p_longitude,
    v_location,
    p_previous_matches,
    p_language,
    p_continent,
    now(),
    0,
    now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    latitude = EXCLUDED.latitude,
    longitude = EXCLUDED.longitude,
    location = EXCLUDED.location,
    previous_matches = EXCLUDED.previous_matches,
    language = EXCLUDED.language,
    continent = EXCLUDED.continent,
    joined_at = now(),
    retry_count = 0,
    last_attempt = now()
  RETURNING id INTO v_queue_id;

  -- Update user status
  UPDATE users 
  SET status = 'waiting', 
      matching_since = now(),
      last_activity = now()
  WHERE id = p_user_id;

  RETURN v_queue_id;
END;
$$;

-- Function 2: Remove from waiting queue
CREATE OR REPLACE FUNCTION remove_from_waiting_queue(
  p_user_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Remove from waiting queue
  DELETE FROM waiting_users WHERE user_id = p_user_id;
  
  -- Update user status
  UPDATE users 
  SET status = 'disconnected',
      matching_since = NULL,
      last_activity = now()
  WHERE id = p_user_id;
  
  RETURN true;
END;
$$;

-- Function 3: Match user
CREATE OR REPLACE FUNCTION match_user(
  p_user_id uuid
) RETURNS TABLE(
  matched_user_id uuid,
  chat_id uuid,
  match_type text,
  distance_km double precision
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_record waiting_users%ROWTYPE;
  v_matched_user_id uuid;
  v_chat_id uuid;
  v_distance double precision;
  v_match_type text;
BEGIN
  -- Get current user from waiting queue
  SELECT * INTO v_user_record
  FROM waiting_users
  WHERE user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Phase 1: Nearby matching (within 100km)
  IF v_user_record.location IS NOT NULL THEN
    SELECT wu.user_id, ST_Distance(v_user_record.location, wu.location) / 1000
    INTO v_matched_user_id, v_distance
    FROM waiting_users wu
    WHERE wu.user_id != p_user_id
      AND wu.location IS NOT NULL
      AND NOT (wu.user_id = ANY(v_user_record.previous_matches))
      AND NOT (p_user_id = ANY(wu.previous_matches))
      AND ST_Distance(v_user_record.location, wu.location) <= 100000
    ORDER BY ST_Distance(v_user_record.location, wu.location)
    LIMIT 1;

    IF FOUND THEN
      v_match_type := 'nearby';
    END IF;
  END IF;

  -- Phase 2: Continental matching
  IF v_matched_user_id IS NULL THEN
    SELECT wu.user_id INTO v_matched_user_id
    FROM waiting_users wu
    WHERE wu.user_id != p_user_id
      AND wu.continent = v_user_record.continent
      AND NOT (wu.user_id = ANY(v_user_record.previous_matches))
      AND NOT (p_user_id = ANY(wu.previous_matches))
    ORDER BY wu.joined_at
    LIMIT 1;

    IF FOUND THEN
      v_match_type := 'continental';
    END IF;
  END IF;

  -- Phase 3: Global matching
  IF v_matched_user_id IS NULL THEN
    SELECT wu.user_id INTO v_matched_user_id
    FROM waiting_users wu
    WHERE wu.user_id != p_user_id
      AND NOT (wu.user_id = ANY(v_user_record.previous_matches))
      AND NOT (p_user_id = ANY(wu.previous_matches))
    ORDER BY wu.joined_at
    LIMIT 1;

    IF FOUND THEN
      v_match_type := 'global';
    END IF;
  END IF;

  -- Phase 4: Desperate matching (ignore previous matches)
  IF v_matched_user_id IS NULL AND v_user_record.retry_count >= 10 THEN
    SELECT wu.user_id INTO v_matched_user_id
    FROM waiting_users wu
    WHERE wu.user_id != p_user_id
    ORDER BY wu.joined_at
    LIMIT 1;

    IF FOUND THEN
      v_match_type := 'desperate';
    END IF;
  END IF;

  -- If match found, create chat and remove from queue
  IF v_matched_user_id IS NOT NULL THEN
    -- Create chat
    INSERT INTO chats (user1_id, user2_id, status)
    VALUES (p_user_id, v_matched_user_id, 'active')
    RETURNING chat_id INTO v_chat_id;

    -- Update both users
    UPDATE users 
    SET status = 'chatting', matching_since = NULL
    WHERE id IN (p_user_id, v_matched_user_id);

    -- Update previous matches
    UPDATE users 
    SET previous_matches = array_append(COALESCE(previous_matches, ARRAY[]::uuid[]), v_matched_user_id)
    WHERE id = p_user_id;

    UPDATE users 
    SET previous_matches = array_append(COALESCE(previous_matches, ARRAY[]::uuid[]), p_user_id)
    WHERE id = v_matched_user_id;

    -- Remove both from waiting queue
    DELETE FROM waiting_users WHERE user_id IN (p_user_id, v_matched_user_id);

    -- Return match result
    matched_user_id := v_matched_user_id;
    chat_id := v_chat_id;
    match_type := v_match_type;
    distance_km := v_distance;
    RETURN NEXT;
  ELSE
    -- Update retry count
    UPDATE waiting_users 
    SET retry_count = retry_count + 1,
        last_attempt = now()
    WHERE user_id = p_user_id;
  END IF;

  RETURN;
END;
$$;

-- Function 4: Cleanup waiting queue
CREATE OR REPLACE FUNCTION cleanup_waiting_queue()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cleaned_count integer;
BEGIN
  -- Remove entries older than 5 minutes
  DELETE FROM waiting_users 
  WHERE joined_at < now() - interval '5 minutes';
  
  GET DIAGNOSTICS v_cleaned_count = ROW_COUNT;
  
  RETURN v_cleaned_count;
END;
$$;

-- Function 5: Get queue statistics
CREATE OR REPLACE FUNCTION get_queue_stats()
RETURNS TABLE(
  total_waiting integer,
  by_continent jsonb,
  average_wait_time text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COUNT(*)::integer as total_waiting,
    jsonb_object_agg(continent, continent_count) as by_continent,
    COALESCE(
      EXTRACT(epoch FROM AVG(now() - joined_at))::text || ' seconds',
      '0 seconds'
    ) as average_wait_time
  FROM (
    SELECT 
      wu.continent,
      COUNT(*) as continent_count,
      wu.joined_at
    FROM waiting_users wu
    GROUP BY wu.continent, wu.joined_at
  ) continent_stats;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION add_to_waiting_queue TO anon, authenticated;
GRANT EXECUTE ON FUNCTION remove_from_waiting_queue TO anon, authenticated;
GRANT EXECUTE ON FUNCTION match_user TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleanup_waiting_queue TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_queue_stats TO anon, authenticated;