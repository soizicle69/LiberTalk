/*
  # Drop and recreate all functions to fix type conflicts

  1. Drop all existing functions first
  2. Recreate all functions with correct signatures
  3. Grant proper permissions
*/

-- Drop all existing functions first
DROP FUNCTION IF EXISTS cleanup_inactive_sessions() CASCADE;
DROP FUNCTION IF EXISTS cleanup_inactive_users() CASCADE;
DROP FUNCTION IF EXISTS join_chat_queue(uuid, double precision, double precision, text, text) CASCADE;
DROP FUNCTION IF EXISTS find_chat_match(uuid) CASCADE;
DROP FUNCTION IF EXISTS leave_chat_queue(uuid) CASCADE;
DROP FUNCTION IF EXISTS get_queue_status() CASCADE;
DROP FUNCTION IF EXISTS update_presence(uuid) CASCADE;
DROP FUNCTION IF EXISTS get_simple_queue_stats() CASCADE;
DROP FUNCTION IF EXISTS find_nearest_match(uuid) CASCADE;
DROP FUNCTION IF EXISTS force_match_waiting_users() CASCADE;

-- Recreate cleanup_inactive_sessions function
CREATE OR REPLACE FUNCTION cleanup_inactive_sessions()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  cleanup_result json;
  deleted_users integer := 0;
  deleted_waiting integer := 0;
  ended_chats integer := 0;
BEGIN
  -- Delete inactive users (offline for more than 5 minutes)
  DELETE FROM users 
  WHERE connection_status = 'offline' 
    AND last_activity < NOW() - INTERVAL '5 minutes';
  GET DIAGNOSTICS deleted_users = ROW_COUNT;

  -- Delete stale waiting_users entries
  DELETE FROM waiting_users 
  WHERE last_ping < NOW() - INTERVAL '2 minutes';
  GET DIAGNOSTICS deleted_waiting = ROW_COUNT;

  -- End chats where users are inactive
  UPDATE chats 
  SET status = 'ended', ended_at = NOW()
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
  GET DIAGNOSTICS ended_chats = ROW_COUNT;

  cleanup_result := json_build_object(
    'deleted_users', deleted_users,
    'deleted_waiting', deleted_waiting,
    'ended_chats', ended_chats,
    'timestamp', NOW()
  );

  RETURN cleanup_result;
END;
$$;

-- Recreate join_chat_queue function
CREATE OR REPLACE FUNCTION join_chat_queue(
  p_user_id uuid,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_continent text DEFAULT 'Unknown',
  p_language text DEFAULT 'en'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result json;
BEGIN
  -- Clean up any existing entry for this user
  DELETE FROM waiting_users WHERE user_id = p_user_id;

  -- Insert user into waiting queue
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
  );

  -- Update user status
  UPDATE users 
  SET status = 'waiting', 
      matching_since = NOW(),
      last_activity = NOW()
  WHERE id = p_user_id;

  result := json_build_object(
    'success', true,
    'message', 'Successfully joined chat queue',
    'user_id', p_user_id,
    'continent', p_continent,
    'language', p_language
  );

  RETURN result;
EXCEPTION
  WHEN OTHERS THEN
    RETURN json_build_object(
      'success', false,
      'error', SQLERRM,
      'message', 'Failed to join chat queue'
    );
END;
$$;

-- Recreate find_chat_match function
CREATE OR REPLACE FUNCTION find_chat_match(p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  current_user_data record;
  potential_partner record;
  new_chat_id uuid;
  result json;
BEGIN
  -- Get current user data
  SELECT wu.*, u.previous_matches
  INTO current_user_data
  FROM waiting_users wu
  JOIN users u ON wu.user_id = u.id
  WHERE wu.user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'success', false,
      'message', 'User not in queue'
    );
  END IF;

  -- Find potential partner with priority matching
  -- Priority 1: Same continent + language, not in previous matches
  SELECT wu.* INTO potential_partner
  FROM waiting_users wu
  JOIN users u ON wu.user_id = u.id
  WHERE wu.user_id != p_user_id
    AND wu.continent = current_user_data.continent
    AND wu.language = current_user_data.language
    AND NOT (wu.user_id = ANY(current_user_data.previous_matches))
    AND u.connection_status = 'online'
    AND wu.last_ping > NOW() - INTERVAL '1 minute'
  ORDER BY wu.joined_at ASC
  LIMIT 1;

  -- Priority 2: Same continent, not in previous matches
  IF NOT FOUND THEN
    SELECT wu.* INTO potential_partner
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.user_id != p_user_id
      AND wu.continent = current_user_data.continent
      AND NOT (wu.user_id = ANY(current_user_data.previous_matches))
      AND u.connection_status = 'online'
      AND wu.last_ping > NOW() - INTERVAL '1 minute'
    ORDER BY wu.joined_at ASC
    LIMIT 1;
  END IF;

  -- Priority 3: Same language, not in previous matches
  IF NOT FOUND THEN
    SELECT wu.* INTO potential_partner
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.user_id != p_user_id
      AND wu.language = current_user_data.language
      AND NOT (wu.user_id = ANY(current_user_data.previous_matches))
      AND u.connection_status = 'online'
      AND wu.last_ping > NOW() - INTERVAL '1 minute'
    ORDER BY wu.joined_at ASC
    LIMIT 1;
  END IF;

  -- Priority 4: Anyone not in previous matches
  IF NOT FOUND THEN
    SELECT wu.* INTO potential_partner
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.user_id != p_user_id
      AND NOT (wu.user_id = ANY(current_user_data.previous_matches))
      AND u.connection_status = 'online'
      AND wu.last_ping > NOW() - INTERVAL '1 minute'
    ORDER BY wu.joined_at ASC
    LIMIT 1;
  END IF;

  -- Priority 5: Anyone available (allow rematching)
  IF NOT FOUND THEN
    SELECT wu.* INTO potential_partner
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE wu.user_id != p_user_id
      AND u.connection_status = 'online'
      AND wu.last_ping > NOW() - INTERVAL '1 minute'
    ORDER BY wu.joined_at ASC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'success', false,
      'message', 'No available partners'
    );
  END IF;

  -- Create new chat
  new_chat_id := gen_random_uuid();
  
  INSERT INTO chats (chat_id, user1_id, user2_id, created_at, status)
  VALUES (new_chat_id, p_user_id, potential_partner.user_id, NOW(), 'active');

  -- Remove both users from waiting queue
  DELETE FROM waiting_users WHERE user_id IN (p_user_id, potential_partner.user_id);

  -- Update user statuses
  UPDATE users 
  SET status = 'chatting',
      matching_since = NULL,
      last_activity = NOW(),
      previous_matches = array_append(previous_matches, potential_partner.user_id)
  WHERE id = p_user_id;

  UPDATE users 
  SET status = 'chatting',
      matching_since = NULL,
      last_activity = NOW(),
      previous_matches = array_append(previous_matches, p_user_id)
  WHERE id = potential_partner.user_id;

  result := json_build_object(
    'success', true,
    'chat_id', new_chat_id,
    'partner_id', potential_partner.user_id,
    'message', 'Match found successfully'
  );

  RETURN result;
EXCEPTION
  WHEN OTHERS THEN
    RETURN json_build_object(
      'success', false,
      'error', SQLERRM,
      'message', 'Error during matching process'
    );
END;
$$;

-- Recreate leave_chat_queue function
CREATE OR REPLACE FUNCTION leave_chat_queue(p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result json;
BEGIN
  -- Remove user from waiting queue
  DELETE FROM waiting_users WHERE user_id = p_user_id;

  -- Update user status
  UPDATE users 
  SET status = 'disconnected',
      matching_since = NULL,
      connection_status = 'offline',
      last_activity = NOW()
  WHERE id = p_user_id;

  result := json_build_object(
    'success', true,
    'message', 'Successfully left chat queue'
  );

  RETURN result;
EXCEPTION
  WHEN OTHERS THEN
    RETURN json_build_object(
      'success', false,
      'error', SQLERRM,
      'message', 'Failed to leave chat queue'
    );
END;
$$;

-- Recreate get_queue_status function
CREATE OR REPLACE FUNCTION get_queue_status()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  total_waiting integer;
  continent_stats json;
  result json;
BEGIN
  -- Get total waiting users
  SELECT COUNT(*) INTO total_waiting
  FROM waiting_users wu
  JOIN users u ON wu.user_id = u.id
  WHERE u.connection_status = 'online'
    AND wu.last_ping > NOW() - INTERVAL '1 minute';

  -- Get stats by continent
  SELECT json_object_agg(continent, user_count) INTO continent_stats
  FROM (
    SELECT wu.continent, COUNT(*) as user_count
    FROM waiting_users wu
    JOIN users u ON wu.user_id = u.id
    WHERE u.connection_status = 'online'
      AND wu.last_ping > NOW() - INTERVAL '1 minute'
    GROUP BY wu.continent
  ) continent_counts;

  result := json_build_object(
    'total_waiting', total_waiting,
    'by_continent', COALESCE(continent_stats, '{}'::json),
    'timestamp', NOW()
  );

  RETURN result;
END;
$$;

-- Recreate update_presence function
CREATE OR REPLACE FUNCTION update_presence(p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result json;
BEGIN
  -- Update user presence
  UPDATE users 
  SET last_activity = NOW(),
      last_seen = NOW(),
      connection_status = 'online'
  WHERE id = p_user_id;

  -- Update waiting queue ping if user is waiting
  UPDATE waiting_users 
  SET last_ping = NOW()
  WHERE user_id = p_user_id;

  result := json_build_object(
    'success', true,
    'message', 'Presence updated',
    'timestamp', NOW()
  );

  RETURN result;
EXCEPTION
  WHEN OTHERS THEN
    RETURN json_build_object(
      'success', false,
      'error', SQLERRM,
      'message', 'Failed to update presence'
    );
END;
$$;

-- Grant permissions to all functions
GRANT EXECUTE ON FUNCTION cleanup_inactive_sessions() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION join_chat_queue(uuid, double precision, double precision, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION find_chat_match(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION leave_chat_queue(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_queue_status() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION update_presence(uuid) TO anon, authenticated;