/*
  # Fix ON CONFLICT error by using alternative approach

  1. Changes
    - Remove ON CONFLICT clause from add_to_waiting_queue function
    - Use DELETE then INSERT pattern instead
    - This avoids the constraint matching issue entirely

  2. Security
    - Maintains existing RLS policies
    - Keeps proper function permissions
*/

-- Drop the existing function
DROP FUNCTION IF EXISTS add_to_waiting_queue(uuid, double precision, double precision, uuid[], text, text);

-- Create the function without ON CONFLICT
CREATE OR REPLACE FUNCTION add_to_waiting_queue(
  p_user_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_previous_matches uuid[],
  p_language text,
  p_continent text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_waiting_id uuid;
  v_location geography;
BEGIN
  -- Create geography point if coordinates are provided
  IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography;
  END IF;

  -- Remove any existing entry for this user first
  DELETE FROM waiting_users WHERE user_id = p_user_id;

  -- Insert new entry
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
    COALESCE(p_previous_matches, ARRAY[]::uuid[]),
    COALESCE(p_language, 'en'),
    COALESCE(p_continent, 'Unknown'),
    now(),
    0,
    now()
  ) RETURNING id INTO v_waiting_id;

  RETURN v_waiting_id;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'Failed to add user to waiting queue: %', SQLERRM;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION add_to_waiting_queue(uuid, double precision, double precision, uuid[], text, text) TO anon, authenticated;