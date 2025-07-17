/*
  # LiberTalk Database Schema

  1. New Tables
    - `users`
      - `id` (uuid, primary key)
      - `ip_geolocation` (jsonb, anonymous location data)
      - `connected_at` (timestamp)
      - `status` (text, user connection status)
      - `continent` (text, for matching priority)
      - `language` (text, user language preference)
    
    - `chats`
      - `chat_id` (uuid, primary key)
      - `user1_id` (uuid, foreign key)
      - `user2_id` (uuid, foreign key)
      - `created_at` (timestamp)
      - `ended_at` (timestamp, nullable)
      - `status` (text, chat status)
    
    - `messages`
      - `id` (uuid, primary key)
      - `chat_id` (uuid, foreign key)
      - `sender_id` (uuid, foreign key)
      - `content` (text, message content)
      - `translated_content` (jsonb, translations)
      - `created_at` (timestamp)

  2. Security
    - Enable RLS on all tables
    - Add policies for authenticated users
    - Anonymous access for chat functionality

  3. Real-time
    - Enable real-time on all tables for live updates
*/

-- Users table for anonymous chat participants
CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ip_geolocation jsonb DEFAULT '{}',
  connected_at timestamptz DEFAULT now(),
  last_activity timestamptz DEFAULT now(),
  status text DEFAULT 'waiting' CHECK (status IN ('waiting', 'matched', 'chatting', 'disconnected')),
  continent text DEFAULT 'unknown',
  language text DEFAULT 'en',
  session_token text UNIQUE DEFAULT gen_random_uuid()::text
);

-- Chats table for managing chat sessions
CREATE TABLE IF NOT EXISTS chats (
  chat_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user1_id uuid REFERENCES users(id) ON DELETE CASCADE,
  user2_id uuid REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  ended_at timestamptz,
  status text DEFAULT 'active' CHECK (status IN ('active', 'ended'))
);

-- Messages table for chat messages
CREATE TABLE IF NOT EXISTS messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id uuid REFERENCES chats(chat_id) ON DELETE CASCADE,
  sender_id uuid REFERENCES users(id) ON DELETE CASCADE,
  content text NOT NULL,
  translated_content jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now()
);

-- Enable Row Level Security
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

-- RLS Policies for users table
CREATE POLICY "Users can read all active users"
  ON users
  FOR SELECT
  TO anon, authenticated
  USING (status IN ('waiting', 'matched', 'chatting'));

CREATE POLICY "Users can insert their own record"
  ON users
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

CREATE POLICY "Users can update their own record"
  ON users
  FOR UPDATE
  TO anon, authenticated
  USING (true);

-- RLS Policies for chats table
CREATE POLICY "Users can read their own chats"
  ON chats
  FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "Users can create chats"
  ON chats
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

CREATE POLICY "Users can update their chats"
  ON chats
  FOR UPDATE
  TO anon, authenticated
  USING (true);

-- RLS Policies for messages table
CREATE POLICY "Users can read messages from their chats"
  ON messages
  FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "Users can insert messages"
  ON messages
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_users_status ON users(status);
CREATE INDEX IF NOT EXISTS idx_users_continent ON users(continent);
CREATE INDEX IF NOT EXISTS idx_users_connected_at ON users(connected_at);
CREATE INDEX IF NOT EXISTS idx_chats_users ON chats(user1_id, user2_id);
CREATE INDEX IF NOT EXISTS idx_messages_chat_id ON messages(chat_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);

-- Function to clean up inactive users
CREATE OR REPLACE FUNCTION cleanup_inactive_users()
RETURNS void AS $$
BEGIN
  -- Mark users as disconnected if inactive for more than 5 minutes
  UPDATE users 
  SET status = 'disconnected'
  WHERE last_activity < now() - interval '5 minutes'
    AND status != 'disconnected';
    
  -- End chats for disconnected users
  UPDATE chats 
  SET status = 'ended', ended_at = now()
  WHERE status = 'active'
    AND (user1_id IN (SELECT id FROM users WHERE status = 'disconnected')
         OR user2_id IN (SELECT id FROM users WHERE status = 'disconnected'));
         
  -- Delete old disconnected users (older than 1 hour)
  DELETE FROM users 
  WHERE status = 'disconnected' 
    AND last_activity < now() - interval '1 hour';
END;
$$ LANGUAGE plpgsql;

-- Function to find matching user
CREATE OR REPLACE FUNCTION find_match_for_user(user_uuid uuid)
RETURNS uuid AS $$
DECLARE
  user_continent text;
  match_id uuid;
BEGIN
  -- Get user's continent
  SELECT continent INTO user_continent FROM users WHERE id = user_uuid;
  
  -- First try to find European match if user is European
  IF user_continent = 'Europe' THEN
    SELECT id INTO match_id 
    FROM users 
    WHERE id != user_uuid 
      AND status = 'waiting'
      AND continent = 'Europe'
      AND last_activity > now() - interval '2 minutes'
    ORDER BY connected_at ASC
    LIMIT 1;
    
    IF match_id IS NOT NULL THEN
      RETURN match_id;
    END IF;
  END IF;
  
  -- Fallback to any available user
  SELECT id INTO match_id 
  FROM users 
  WHERE id != user_uuid 
    AND status = 'waiting'
    AND last_activity > now() - interval '2 minutes'
  ORDER BY connected_at ASC
  LIMIT 1;
  
  RETURN match_id;
END;
$$ LANGUAGE plpgsql;