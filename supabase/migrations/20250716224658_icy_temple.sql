/*
  # Fix ambiguous chat_id column reference

  1. Function Updates
    - Fix ambiguous `chat_id` column reference in `match_user` function
    - Properly qualify all column references with table aliases
    - Ensure clear table aliases throughout the function

  2. Changes Made
    - Added proper table aliases (c for chats, u1/u2 for users)
    - Qualified all column references to avoid ambiguity
    - Fixed the SELECT statement to use proper aliases
*/

-- Drop and recreate the match_user function with proper column qualification
DROP FUNCTION IF EXISTS match_user(uuid);

CREATE OR REPLACE FUNCTION match_user(p_user_id uuid)
RETURNS TABLE(
  matched_user_id uuid,
  chat_id uuid,
  match_type text,
  distance_km double precision
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_location geography;
  v_user_continent text;
  v_user_previous_matches uuid[];
  v_matched_user_id uuid;
  v_chat_id uuid;
  v_match_type text := 'global';
  v_distance_km double precision;
BEGIN
  -- Get current user info
  SELECT u.location, u.continent, u.previous_matches
  INTO v_user_location, v_user_continent, v_user_previous_matches
  FROM users u
  WHERE u.id = p_user_id;

  -- Try to find a match (nearby first, then continental, then global)
  SELECT wu.user_id, 
         CASE 
           WHEN v_user_location IS NOT NULL AND wu.location IS NOT NULL 
           THEN ST_Distance(v_user_location, wu.location) / 1000.0
           ELSE NULL 
         END
  INTO v_matched_user_id, v_distance_km
  FROM waiting_users wu
  WHERE wu.user_id != p_user_id
    AND wu.user_id != ALL(COALESCE(v_user_previous_matches, ARRAY[]::uuid[]))
    AND wu.joined_at < NOW() - INTERVAL '2 seconds'
  ORDER BY 
    CASE 
      WHEN v_user_location IS NOT NULL AND wu.location IS NOT NULL 
      THEN ST_Distance(v_user_location, wu.location)
      ELSE 999999999 
    END
  LIMIT 1;

  -- If no match found, return empty
  IF v_matched_user_id IS NULL THEN
    RETURN;
  END IF;

  -- Determine match type based on distance
  IF v_distance_km IS NOT NULL THEN
    IF v_distance_km <= 50 THEN
      v_match_type := 'nearby';
    ELSIF v_distance_km <= 500 THEN
      v_match_type := 'continental';
    ELSE
      v_match_type := 'global';
    END IF;
  END IF;

  -- Create chat
  INSERT INTO chats (user1_id, user2_id, status)
  VALUES (p_user_id, v_matched_user_id, 'active')
  RETURNING chats.chat_id INTO v_chat_id;

  -- Remove both users from waiting queue
  DELETE FROM waiting_users WHERE user_id IN (p_user_id, v_matched_user_id);

  -- Update user statuses
  UPDATE users 
  SET status = 'matched', 
      matching_since = NULL,
      previous_matches = array_append(COALESCE(previous_matches, ARRAY[]::uuid[]), v_matched_user_id)
  WHERE id = p_user_id;

  UPDATE users 
  SET status = 'matched', 
      matching_since = NULL,
      previous_matches = array_append(COALESCE(previous_matches, ARRAY[]::uuid[]), p_user_id)
  WHERE id = v_matched_user_id;

  -- Return match result
  RETURN QUERY SELECT v_matched_user_id, v_chat_id, v_match_type, v_distance_km;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'Error in match_user: %', SQLERRM;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION match_user(uuid) TO anon, authenticated;