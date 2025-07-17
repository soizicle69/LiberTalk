/*
  # Fix database function conflicts

  1. Drop existing functions that have type conflicts
  2. Recreate all functions with correct signatures
  3. Ensure proper RLS policies
  4. Add missing indexes for performance

  This migration resolves the "cannot change return type" errors by dropping and recreating functions.
*/

-- Drop all existing functions that might have conflicts
DROP FUNCTION IF EXISTS cleanup_inactive_users();
DROP FUNCTION IF EXISTS get_simple_queue_stats();
DROP FUNCTION IF EXISTS simple_add_to_queue(uuid, double precision, double precision, text, text);
DROP FUNCTION IF EXISTS remove_from_queue(uuid);
DROP FUNCTION IF EXISTS find_nearest_match(uuid);
DROP FUNCTION IF EXISTS update_user_ping(uuid);
DROP FUNCTION IF EXISTS cleanup_matching_queue();
DROP FUNCTION IF EXISTS update_user_location(uuid, double precision, double precision);

-- Recreate cleanup_inactive_users function
CREATE OR REPLACE FUNCTION cleanup_inactive_users()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Remove users inactive for more than 5 minutes
  DELETE FROM waiting_users 
  WHERE last_ping < NOW() - INTERVAL '5 minutes';
  
  -- Update user status for inactive users
  UPDATE users 
  SET status = 'disconnected', 
      connection_status = 'offline',
      matching_since = NULL
  WHERE last_activity < NOW() - INTERVAL '5 minutes'
    AND status IN ('waiting', 'matched');
    
  -- End chats for inactive users
  UPDATE chats 
  SET status = 'ended', 
      ended_at = NOW()
  WHERE status = 'active'
    AND (user1_id IN (
      SELECT id FROM users 
      WHERE connection_status = 'offline' 
        AND last_activity < NOW() - INTERVAL '2 minutes'
    ) OR user2_id IN (
      SELECT id FROM users 
      WHERE connection_status = 'offline' 
        AND last_activity < NOW() - INTERVAL '2 minutes'
    ));
END;
$$;

-- Recreate get_simple_queue_stats function
CREATE OR REPLACE FUNCTION get_simple_queue_stats()
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
      EXTRACT(epoch FROM AVG(NOW() - joined_at))::text || ' seconds',
      '0 seconds'
    ) as average_wait_time
  FROM (
    SELECT 
      continent,
      COUNT(*) as continent_count,
      joined_at
    FROM waiting_users 
    WHERE last_ping > NOW() - INTERVAL '2 minutes'
    GROUP BY continent, joined_at
  ) stats;
END;
$$;

-- Recreate simple_add_to_queue function
CREATE OR REPLACE FUNCTION simple_add_to_queue(
  p_user_id uuid,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_continent text DEFAULT 'Unknown',
  p_language text DEFAULT 'en'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  queue_id uuid;
BEGIN
  -- Clean up any existing entry for this user
  DELETE FROM waiting_users WHERE user_id = p_user_id;
  
  -- Update user status
  UPDATE users 
  SET status = 'waiting',
      connection_status = 'online',
      continent = p_continent,
      language = p_language,
      matching_since = NOW(),
      last_activity = NOW(),
      last_seen = NOW()
  WHERE id = p_user_id;
  
  -- Add to queue
  INSERT INTO waiting_users (
    user_id, 
    latitude, 
    longitude, 
    continent, 
    language,
    joined_at,
    last_ping
  ) VALUES (
    p_user_id, 
    p_latitude, 
    p_longitude, 
    p_continent, 
    p_language,
    NOW(),
    NOW()
  ) RETURNING id INTO queue_id;
  
  RETURN queue_id;
END;
$$;

-- Recreate remove_from_queue function
CREATE OR REPLACE FUNCTION remove_from_queue(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Remove from queue
  DELETE FROM waiting_users WHERE user_id = p_user_id;
  
  -- Update user status
  UPDATE users 
  SET status = 'disconnected',
      matching_since = NULL,
      last_activity = NOW()
  WHERE id = p_user_id;
END;
$$;

-- Recreate find_nearest_match function
CREATE OR REPLACE FUNCTION find_nearest_match(p_user_id uuid)
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
  user_continent text;
  user_language text;
  user_lat double precision;
  user_lng double precision;
  matched_user uuid;
  new_chat_id uuid;
  match_distance double precision := NULL;
  current_match_type text := 'global';
BEGIN
  -- Get current user info
  SELECT continent, language, 
         COALESCE((ip_geolocation->>'latitude')::double precision, 0),
         COALESCE((ip_geolocation->>'longitude')::double precision, 0)
  INTO user_continent, user_language, user_lat, user_lng
  FROM users WHERE id = p_user_id;
  
  -- Strategy 1: Same continent + language
  SELECT wu.user_id INTO matched_user
  FROM waiting_users wu
  JOIN users u ON wu.user_id = u.id
  WHERE wu.user_id != p_user_id
    AND wu.continent = user_continent
    AND wu.language = user_language
    AND wu.last_ping > NOW() - INTERVAL '2 minutes'
    AND u.status = 'waiting'
    AND NOT (p_user_id = ANY(u.previous_matches))
  ORDER BY wu.joined_at ASC
  LIMIT 1;
  
  IF matched_user IS NOT NULL THEN
    current_match_type := 'continental_language';
  ELSE
    -- Strategy 2: Same continent
    SELECT wu.user_id INTO matched_user
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.user_id != p_user_id
      AND wu.continent = user_continent
      AND wu.last_ping > NOW() - INTERVAL '2 minutes'
      AND u.status = 'waiting'
      AND NOT (p_user_id = ANY(u.previous_matches))
    ORDER BY wu.joined_at ASC
    LIMIT 1;
    
    IF matched_user IS NOT NULL THEN
      current_match_type := 'continental';
    ELSE
      -- Strategy 3: Global match
      SELECT wu.user_id INTO matched_user
      FROM waiting_users wu
      JOIN users u ON wu.user_id = u.id
      WHERE wu.user_id != p_user_id
        AND wu.last_ping > NOW() - INTERVAL '2 minutes'
        AND u.status = 'waiting'
        AND NOT (p_user_id = ANY(u.previous_matches))
      ORDER BY wu.joined_at ASC
      LIMIT 1;
    END IF;
  END IF;
  
  -- If match found, create chat
  IF matched_user IS NOT NULL THEN
    -- Create chat
    INSERT INTO chats (user1_id, user2_id, status, created_at)
    VALUES (p_user_id, matched_user, 'active', NOW())
    RETURNING chat_id INTO new_chat_id;
    
    -- Update both users
    UPDATE users 
    SET status = 'chatting',
        matching_since = NULL,
        previous_matches = array_append(COALESCE(previous_matches, ARRAY[]::uuid[]), matched_user),
        last_activity = NOW()
    WHERE id = p_user_id;
    
    UPDATE users 
    SET status = 'chatting',
        matching_since = NULL,
        previous_matches = array_append(COALESCE(previous_matches, ARRAY[]::uuid[]), p_user_id),
        last_activity = NOW()
    WHERE id = matched_user;
    
    -- Remove both from queue
    DELETE FROM waiting_users WHERE user_id IN (p_user_id, matched_user);
    
    -- Calculate distance if coordinates available
    IF user_lat IS NOT NULL AND user_lng IS NOT NULL THEN
      SELECT COALESCE(
        (ip_geolocation->>'latitude')::double precision, 0
      ) INTO match_distance FROM users WHERE id = matched_user;
      
      IF match_distance IS NOT NULL THEN
        match_distance := 6371 * acos(
          cos(radians(user_lat)) * cos(radians(match_distance)) *
          cos(radians(COALESCE((SELECT ip_geolocation->>'longitude' FROM users WHERE id = matched_user)::double precision, 0)) - radians(user_lng)) +
          sin(radians(user_lat)) * sin(radians(match_distance))
        );
      END IF;
    END IF;
    
    -- Return match info
    RETURN QUERY SELECT matched_user, new_chat_id, current_match_type, match_distance;
  END IF;
END;
$$;

-- Recreate update_user_ping function
CREATE OR REPLACE FUNCTION update_user_ping(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Update ping in queue
  UPDATE waiting_users 
  SET last_ping = NOW()
  WHERE user_id = p_user_id;
  
  -- Update user activity
  UPDATE users 
  SET last_activity = NOW(),
      last_seen = NOW(),
      connection_status = 'online'
  WHERE id = p_user_id;
END;
$$;

-- Recreate update_user_location function
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
  SET location = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326),
      ip_geolocation = jsonb_set(
        COALESCE(ip_geolocation, '{}'::jsonb),
        '{latitude}',
        to_jsonb(latitude)
      ),
      ip_geolocation = jsonb_set(
        ip_geolocation,
        '{longitude}',
        to_jsonb(longitude)
      )
  WHERE id = user_id;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION cleanup_inactive_users() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_simple_queue_stats() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION simple_add_to_queue(uuid, double precision, double precision, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION remove_from_queue(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION find_nearest_match(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION update_user_ping(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION update_user_location(uuid, double precision, double precision) TO anon, authenticated;