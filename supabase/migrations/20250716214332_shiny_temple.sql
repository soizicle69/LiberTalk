/*
  # Fix function return type conflicts

  1. Drop existing functions that have return type conflicts
  2. Recreate them with correct return types
  3. Ensure all functions work properly with PostGIS
*/

-- Drop existing functions to avoid return type conflicts
DROP FUNCTION IF EXISTS cleanup_inactive_users();
DROP FUNCTION IF EXISTS find_nearest_match(uuid, geometry, integer);
DROP FUNCTION IF EXISTS update_user_location(uuid, double precision, double precision);

-- Recreate cleanup function with void return type
CREATE OR REPLACE FUNCTION cleanup_inactive_users()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Delete users inactive for more than 30 minutes
  DELETE FROM users 
  WHERE last_activity < NOW() - INTERVAL '30 minutes'
    AND status != 'chatting';
    
  -- Update chatting users to disconnected if inactive for 10 minutes
  UPDATE users 
  SET status = 'disconnected'
  WHERE last_activity < NOW() - INTERVAL '10 minutes'
    AND status = 'chatting';
END;
$$;

-- Recreate location update function
CREATE OR REPLACE FUNCTION update_user_location(
  user_id uuid,
  latitude double precision,
  longitude double precision
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE users 
  SET location = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)
  WHERE id = user_id;
END;
$$;

-- Recreate find nearest match function with correct return type
CREATE OR REPLACE FUNCTION find_nearest_match(
  user_id uuid,
  user_location geometry DEFAULT NULL,
  max_distance_km integer DEFAULT 1000
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  matched_user_id uuid;
  fallback_user_id uuid;
BEGIN
  -- First try: Find nearby users if location is provided
  IF user_location IS NOT NULL THEN
    SELECT id INTO matched_user_id
    FROM (
      SELECT u.id,
             ST_Distance(u.location::geography, user_location::geography) / 1000 as distance_km
      FROM users u
      WHERE u.id != user_id
        AND u.status = 'waiting'
        AND u.last_activity > NOW() - INTERVAL '5 minutes'
        AND u.location IS NOT NULL
        AND NOT (u.id = ANY(
          SELECT previous_matches 
          FROM users 
          WHERE id = user_id
        ))
        AND ST_Distance(u.location::geography, user_location::geography) / 1000 <= max_distance_km
      ORDER BY distance_km ASC
      LIMIT 10
    ) nearby_users
    ORDER BY RANDOM()
    LIMIT 1;
  END IF;

  -- If no nearby match found, try global matching
  IF matched_user_id IS NULL THEN
    SELECT id INTO fallback_user_id
    FROM users u
    WHERE u.id != user_id
      AND u.status = 'waiting'
      AND u.last_activity > NOW() - INTERVAL '5 minutes'
      AND NOT (u.id = ANY(
        SELECT COALESCE(previous_matches, '{}') 
        FROM users 
        WHERE id = user_id
      ))
    ORDER BY RANDOM()
    LIMIT 1;
    
    matched_user_id := fallback_user_id;
  END IF;

  -- Update both users' previous matches if match found
  IF matched_user_id IS NOT NULL THEN
    -- Update current user's previous matches
    UPDATE users 
    SET previous_matches = COALESCE(previous_matches, '{}') || ARRAY[matched_user_id],
        status = 'matched'
    WHERE id = user_id;
    
    -- Update matched user's previous matches
    UPDATE users 
    SET previous_matches = COALESCE(previous_matches, '{}') || ARRAY[user_id],
        status = 'matched'
    WHERE id = matched_user_id;
  END IF;

  RETURN matched_user_id;
END;
$$;