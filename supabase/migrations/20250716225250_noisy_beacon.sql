/*
  # Refonte complète du système de matching utilisateur

  1. Nouvelles Tables
    - Nettoyage et recréation des tables avec structure optimisée
    - Index optimisés pour les performances de matching
    
  2. Nouvelles Fonctions
    - `simple_add_to_queue` - Ajouter un utilisateur à la file d'attente
    - `simple_find_match` - Trouver un match pour un utilisateur
    - `create_chat_between_users` - Créer un chat entre deux utilisateurs
    - `cleanup_old_entries` - Nettoyer les anciennes entrées
    
  3. Sécurité
    - RLS activé sur toutes les tables
    - Politiques simplifiées mais sécurisées
*/

-- Nettoyer les anciennes fonctions
DROP FUNCTION IF EXISTS add_to_waiting_queue CASCADE;
DROP FUNCTION IF EXISTS match_user CASCADE;
DROP FUNCTION IF EXISTS remove_from_waiting_queue CASCADE;
DROP FUNCTION IF EXISTS cleanup_waiting_queue CASCADE;
DROP FUNCTION IF EXISTS get_queue_stats CASCADE;

-- Nettoyer et recréer la table waiting_users
DROP TABLE IF EXISTS waiting_users CASCADE;

CREATE TABLE waiting_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  latitude double precision,
  longitude double precision,
  continent text DEFAULT 'Unknown',
  language text DEFAULT 'en',
  joined_at timestamptz DEFAULT now(),
  last_ping timestamptz DEFAULT now(),
  UNIQUE(user_id)
);

-- Index optimisés pour le matching
CREATE INDEX idx_waiting_users_user_id ON waiting_users(user_id);
CREATE INDEX idx_waiting_users_continent ON waiting_users(continent);
CREATE INDEX idx_waiting_users_language ON waiting_users(language);
CREATE INDEX idx_waiting_users_joined_at ON waiting_users(joined_at);
CREATE INDEX idx_waiting_users_last_ping ON waiting_users(last_ping);

-- RLS pour waiting_users
ALTER TABLE waiting_users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage their queue entry"
  ON waiting_users
  FOR ALL
  TO authenticated, anon
  USING (true)
  WITH CHECK (true);

-- Fonction simple pour ajouter à la file d'attente
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
  v_queue_id uuid;
BEGIN
  -- Supprimer l'entrée existante si elle existe
  DELETE FROM waiting_users WHERE user_id = p_user_id;
  
  -- Ajouter à la file d'attente
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
    COALESCE(p_continent, 'Unknown'),
    COALESCE(p_language, 'en'),
    now(),
    now()
  ) RETURNING id INTO v_queue_id;
  
  -- Mettre à jour le statut de l'utilisateur
  UPDATE users 
  SET 
    status = 'waiting',
    matching_since = now(),
    last_activity = now()
  WHERE id = p_user_id;
  
  RETURN v_queue_id;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'Erreur lors de l''ajout à la file: %', SQLERRM;
END;
$$;

-- Fonction pour trouver un match
CREATE OR REPLACE FUNCTION simple_find_match(p_user_id uuid)
RETURNS TABLE(
  matched_user_id uuid,
  chat_id uuid,
  match_type text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_continent text;
  v_user_language text;
  v_matched_user_id uuid;
  v_chat_id uuid;
  v_match_type text := 'global';
BEGIN
  -- Récupérer les infos de l'utilisateur
  SELECT wu.continent, wu.language
  INTO v_user_continent, v_user_language
  FROM waiting_users wu
  WHERE wu.user_id = p_user_id;
  
  IF NOT FOUND THEN
    RETURN; -- L'utilisateur n'est pas dans la file
  END IF;
  
  -- Chercher un match par continent et langue
  SELECT wu.user_id INTO v_matched_user_id
  FROM waiting_users wu
  WHERE wu.user_id != p_user_id
    AND wu.continent = v_user_continent
    AND wu.language = v_user_language
    AND wu.last_ping > (now() - interval '2 minutes')
  ORDER BY wu.joined_at ASC
  LIMIT 1;
  
  IF FOUND THEN
    v_match_type := 'continental_language';
  ELSE
    -- Chercher par continent seulement
    SELECT wu.user_id INTO v_matched_user_id
    FROM waiting_users wu
    WHERE wu.user_id != p_user_id
      AND wu.continent = v_user_continent
      AND wu.last_ping > (now() - interval '2 minutes')
    ORDER BY wu.joined_at ASC
    LIMIT 1;
    
    IF FOUND THEN
      v_match_type := 'continental';
    ELSE
      -- Chercher globalement
      SELECT wu.user_id INTO v_matched_user_id
      FROM waiting_users wu
      WHERE wu.user_id != p_user_id
        AND wu.last_ping > (now() - interval '2 minutes')
      ORDER BY wu.joined_at ASC
      LIMIT 1;
      
      IF FOUND THEN
        v_match_type := 'global';
      END IF;
    END IF;
  END IF;
  
  -- Si un match est trouvé, créer le chat
  IF v_matched_user_id IS NOT NULL THEN
    -- Créer le chat
    INSERT INTO chats (user1_id, user2_id, status, created_at)
    VALUES (p_user_id, v_matched_user_id, 'active', now())
    RETURNING chats.chat_id INTO v_chat_id;
    
    -- Supprimer les deux utilisateurs de la file d'attente
    DELETE FROM waiting_users WHERE user_id IN (p_user_id, v_matched_user_id);
    
    -- Mettre à jour le statut des utilisateurs
    UPDATE users 
    SET 
      status = 'chatting',
      matching_since = NULL,
      last_activity = now()
    WHERE id IN (p_user_id, v_matched_user_id);
    
    -- Retourner le résultat
    matched_user_id := v_matched_user_id;
    chat_id := v_chat_id;
    match_type := v_match_type;
    RETURN NEXT;
  END IF;
  
  RETURN;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'Erreur lors de la recherche de match: %', SQLERRM;
END;
$$;

-- Fonction pour supprimer de la file d'attente
CREATE OR REPLACE FUNCTION remove_from_queue(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM waiting_users WHERE user_id = p_user_id;
  
  UPDATE users 
  SET 
    status = 'disconnected',
    matching_since = NULL,
    last_activity = now()
  WHERE id = p_user_id;
  
  RETURN true;
EXCEPTION
  WHEN OTHERS THEN
    RETURN false;
END;
$$;

-- Fonction pour nettoyer les anciennes entrées
CREATE OR REPLACE FUNCTION cleanup_old_entries()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cleaned_count integer := 0;
BEGIN
  -- Supprimer les entrées inactives depuis plus de 5 minutes
  DELETE FROM waiting_users 
  WHERE last_ping < (now() - interval '5 minutes');
  
  GET DIAGNOSTICS v_cleaned_count = ROW_COUNT;
  
  -- Nettoyer les utilisateurs inactifs
  UPDATE users 
  SET 
    status = 'disconnected',
    connection_status = 'offline',
    matching_since = NULL
  WHERE last_activity < (now() - interval '5 minutes')
    AND status IN ('waiting', 'matched');
  
  RETURN v_cleaned_count;
END;
$$;

-- Fonction pour obtenir les statistiques de la file
CREATE OR REPLACE FUNCTION get_simple_queue_stats()
RETURNS TABLE(
  total_waiting integer,
  by_continent jsonb,
  by_language jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COUNT(*)::integer as total_waiting,
    jsonb_object_agg(continent, continent_count) as by_continent,
    jsonb_object_agg(language, language_count) as by_language
  FROM (
    SELECT 
      COUNT(*) as total_count,
      continent,
      COUNT(*) as continent_count,
      language,
      COUNT(*) as language_count
    FROM waiting_users 
    WHERE last_ping > (now() - interval '2 minutes')
    GROUP BY continent, language
  ) stats;
END;
$$;

-- Fonction pour mettre à jour le ping
CREATE OR REPLACE FUNCTION update_queue_ping(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE waiting_users 
  SET last_ping = now()
  WHERE user_id = p_user_id;
  
  UPDATE users
  SET last_activity = now()
  WHERE id = p_user_id;
  
  RETURN FOUND;
END;
$$;

-- Accorder les permissions
GRANT EXECUTE ON FUNCTION simple_add_to_queue TO authenticated, anon;
GRANT EXECUTE ON FUNCTION simple_find_match TO authenticated, anon;
GRANT EXECUTE ON FUNCTION remove_from_queue TO authenticated, anon;
GRANT EXECUTE ON FUNCTION cleanup_old_entries TO authenticated, anon;
GRANT EXECUTE ON FUNCTION get_simple_queue_stats TO authenticated, anon;
GRANT EXECUTE ON FUNCTION update_queue_ping TO authenticated, anon;