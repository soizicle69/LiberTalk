/*
  # Fix timestamp type mismatches in Bazoocam matching

  1. Database Function Fixes
    - Fix `matching_since` timestamp comparisons
    - Ensure all timestamp operations use proper types
    - Add proper interval calculations

  2. Function Updates
    - Update `find_bazoocam_match` with correct timestamp handling
    - Fix `cleanup_inactive_sessions` timestamp logic
    - Ensure consistent timestamp with time zone usage
*/

-- Drop existing functions to recreate with fixes
DROP FUNCTION IF EXISTS find_bazoocam_match(uuid, geometry, integer);
DROP FUNCTION IF EXISTS cleanup_inactive_sessions();

-- Fixed find_bazoocam_match function with proper timestamp handling
CREATE OR REPLACE FUNCTION find_bazoocam_match(
  user_id uuid,
  user_location geometry DEFAULT NULL,
  max_nearby_distance_km integer DEFAULT 1000
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  match_id uuid;
  current_time timestamptz := NOW();
BEGIN
  -- Phase 1: Try nearby matching if location provided
  IF user_location IS NOT NULL AND max_nearby_distance_km IS NOT NULL THEN
    SELECT u.id INTO match_id
    FROM users u
    WHERE u.id != user_id
      AND u.status = 'waiting'
      AND u.connection_status = 'online'
      AND u.last_activity > (current_time - INTERVAL '2 minutes')
      AND u.matching_since IS NOT NULL
      AND u.matching_since < (current_time - INTERVAL '1 second')
      AND u.location IS NOT NULL
      AND NOT (user_id = ANY(COALESCE(u.previous_matches, ARRAY[]::uuid[])))
      AND NOT (u.id = ANY(
        SELECT COALESCE(prev.previous_matches, ARRAY[]::uuid[])
        FROM users prev WHERE prev.id = user_id
      ))
      AND ST_DWithin(
        u.location::geography,
        user_location::geography,
        max_nearby_distance_km * 1000
      )
    ORDER BY ST_Distance(u.location::geography, user_location::geography)
    LIMIT 1;
    
    IF match_id IS NOT NULL THEN
      RETURN match_id;
    END IF;
  END IF;

  -- Phase 2: Regional matching (same continent)
  SELECT u.id INTO match_id
  FROM users u
  WHERE u.id != user_id
    AND u.status = 'waiting'
    AND u.connection_status = 'online'
    AND u.last_activity > (current_time - INTERVAL '5 minutes')
    AND u.matching_since IS NOT NULL
    AND u.matching_since < (current_time - INTERVAL '2 seconds')
    AND u.continent = (SELECT continent FROM users WHERE id = user_id)
    AND NOT (user_id = ANY(COALESCE(u.previous_matches, ARRAY[]::uuid[])))
    AND NOT (u.id = ANY(
      SELECT COALESCE(prev.previous_matches, ARRAY[]::uuid[])
      FROM users prev WHERE prev.id = user_id
    ))
  ORDER BY u.matching_since ASC
  LIMIT 1;
  
  IF match_id IS NOT NULL THEN
    RETURN match_id;
  END IF;

  -- Phase 3: Global matching (any continent)
  SELECT u.id INTO match_id
  FROM users u
  WHERE u.id != user_id
    AND u.status = 'waiting'
    AND u.connection_status = 'online'
    AND u.last_activity > (current_time - INTERVAL '10 minutes')
    AND u.matching_since IS NOT NULL
    AND u.matching_since < (current_time - INTERVAL '3 seconds')
    AND NOT (user_id = ANY(COALESCE(u.previous_matches, ARRAY[]::uuid[])))
    AND NOT (u.id = ANY(
      SELECT COALESCE(prev.previous_matches, ARRAY[]::uuid[])
      FROM users prev WHERE prev.id = user_id
    ))
  ORDER BY u.matching_since ASC
  LIMIT 1;
  
  IF match_id IS NOT NULL THEN
    RETURN match_id;
  END IF;

  -- Phase 4: Emergency fallback (any waiting user, ignore previous matches)
  SELECT u.id INTO match_id
  FROM users u
  WHERE u.id != user_id
    AND u.status = 'waiting'
    AND u.connection_status = 'online'
    AND u.last_activity > (current_time - INTERVAL '30 minutes')
  ORDER BY u.matching_since ASC NULLS LAST
  LIMIT 1;

  RETURN match_id;
END;
$$;

-- Fixed cleanup function with proper timestamp handling
CREATE OR REPLACE FUNCTION cleanup_inactive_sessions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  current_time timestamptz := NOW();
BEGIN
  -- Update users who haven't been active recently
  UPDATE users 
  SET 
    status = 'disconnected',
    connection_status = 'offline',
    matching_since = NULL
  WHERE 
    last_activity < (current_time - INTERVAL '5 minutes')
    AND status IN ('waiting', 'matched')
    AND connection_status = 'online';

  -- End chats where users are inactive
  UPDATE chats 
  SET 
    status = 'ended',
    ended_at = current_time
  WHERE 
    status = 'active'
    AND (
      user1_id IN (
        SELECT id FROM users 
        WHERE last_activity < (current_time - INTERVAL '5 minutes')
      )
      OR user2_id IN (
        SELECT id FROM users 
        WHERE last_activity < (current_time - INTERVAL '5 minutes')
      )
    );

  -- Clean up very old disconnected users
  DELETE FROM users 
  WHERE 
    status = 'disconnected' 
    AND last_activity < (current_time - INTERVAL '1 hour');
END;
$$;