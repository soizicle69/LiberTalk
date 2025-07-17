/*
  # Fix ambiguous column reference in find_nearest_match function

  1. Database Functions
    - Drop and recreate `find_nearest_match` function with proper table aliases
    - Fix ambiguous `chat_id` column reference by using proper table prefixes

  2. Security
    - Maintain existing RLS and permissions
*/

-- Drop the existing function to avoid conflicts
DROP FUNCTION IF EXISTS find_nearest_match(uuid);

-- Recreate the function with proper table aliases to fix ambiguous column reference
CREATE OR REPLACE FUNCTION find_nearest_match(p_user_id uuid)
RETURNS TABLE (
  matched_user_id uuid,
  chat_id uuid,
  match_type text,
  distance_km double precision
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_continent text;
  v_user_language text;
  v_user_lat double precision;
  v_user_lng double precision;
  v_matched_user_id uuid;
  v_chat_id uuid;
  v_distance double precision;
BEGIN
  -- Get current user info
  SELECT continent, language, 
         (ip_geolocation->>'latitude')::double precision,
         (ip_geolocation->>'longitude')::double precision
  INTO v_user_continent, v_user_language, v_user_lat, v_user_lng
  FROM users 
  WHERE id = p_user_id;

  -- Try to find a match with continent + language priority
  SELECT wu.user_id INTO v_matched_user_id
  FROM waiting_users wu
  WHERE wu.user_id != p_user_id
    AND wu.continent = v_user_continent
    AND wu.language = v_user_language
    AND wu.last_ping > NOW() - INTERVAL '2 minutes'
    AND NOT (wu.user_id = ANY(
      SELECT unnest(previous_matches) 
      FROM users 
      WHERE id = p_user_id
    ))
  ORDER BY wu.joined_at ASC
  LIMIT 1;

  -- If no continent+language match, try continent only
  IF v_matched_user_id IS NULL THEN
    SELECT wu.user_id INTO v_matched_user_id
    FROM waiting_users wu
    WHERE wu.user_id != p_user_id
      AND wu.continent = v_user_continent
      AND wu.last_ping > NOW() - INTERVAL '2 minutes'
      AND NOT (wu.user_id = ANY(
        SELECT unnest(previous_matches) 
        FROM users 
        WHERE id = p_user_id
      ))
    ORDER BY wu.joined_at ASC
    LIMIT 1;
  END IF;

  -- If still no match, try global
  IF v_matched_user_id IS NULL THEN
    SELECT wu.user_id INTO v_matched_user_id
    FROM waiting_users wu
    WHERE wu.user_id != p_user_id
      AND wu.last_ping > NOW() - INTERVAL '2 minutes'
      AND NOT (wu.user_id = ANY(
        SELECT unnest(previous_matches) 
        FROM users 
        WHERE id = p_user_id
      ))
    ORDER BY wu.joined_at ASC
    LIMIT 1;
  END IF;

  -- If we found a match, create the chat
  IF v_matched_user_id IS NOT NULL THEN
    -- Create chat with explicit column references
    INSERT INTO chats (user1_id, user2_id, status)
    VALUES (p_user_id, v_matched_user_id, 'active')
    RETURNING chats.chat_id INTO v_chat_id;  -- Use explicit table prefix

    -- Remove both users from waiting queue
    DELETE FROM waiting_users WHERE user_id IN (p_user_id, v_matched_user_id);

    -- Update user statuses
    UPDATE users 
    SET status = 'chatting',
        previous_matches = array_append(previous_matches, v_matched_user_id)
    WHERE id = p_user_id;

    UPDATE users 
    SET status = 'chatting',
        previous_matches = array_append(previous_matches, p_user_id)
    WHERE id = v_matched_user_id;

    -- Calculate distance if coordinates available
    IF v_user_lat IS NOT NULL AND v_user_lng IS NOT NULL THEN
      SELECT wu.latitude, wu.longitude INTO v_user_lat, v_user_lng
      FROM waiting_users wu WHERE wu.user_id = v_matched_user_id;
      
      IF v_user_lat IS NOT NULL AND v_user_lng IS NOT NULL THEN
        v_distance := 6371 * acos(
          cos(radians(v_user_lat)) * 
          cos(radians((SELECT (ip_geolocation->>'latitude')::double precision FROM users WHERE id = v_matched_user_id))) * 
          cos(radians((SELECT (ip_geolocation->>'longitude')::double precision FROM users WHERE id = v_matched_user_id)) - radians(v_user_lng)) + 
          sin(radians(v_user_lat)) * 
          sin(radians((SELECT (ip_geolocation->>'latitude')::double precision FROM users WHERE id = v_matched_user_id)))
        );
      END IF;
    END IF;

    -- Return match result
    RETURN QUERY SELECT 
      v_matched_user_id,
      v_chat_id,
      CASE 
        WHEN v_user_continent = (SELECT continent FROM users WHERE id = v_matched_user_id) 
         AND v_user_language = (SELECT language FROM users WHERE id = v_matched_user_id) 
        THEN 'continental_language'::text
        WHEN v_user_continent = (SELECT continent FROM users WHERE id = v_matched_user_id) 
        THEN 'continental'::text
        ELSE 'global'::text
      END,
      COALESCE(v_distance, 0.0);
  END IF;

  RETURN;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION find_nearest_match(uuid) TO anon, authenticated;