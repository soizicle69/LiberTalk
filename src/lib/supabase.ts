import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing Supabase environment variables');
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  realtime: {
    params: {
      eventsPerSecond: 20,
    },
  },
});

// Database types
export interface User {
  id: string;
  ip_geolocation: any;
  connected_at: string;
  last_activity: string;
  status: 'waiting' | 'matched' | 'chatting' | 'disconnected';
  continent: string;
  language: string;
  session_token: string;
}

export interface Chat {
  chat_id: string;
  user1_id: string;
  user2_id: string;
  created_at: string;
  ended_at?: string;
  status: 'active' | 'ended';
}

export interface Message {
  id: string;
  chat_id: string;
  sender_id: string;
  content: string;
  translated_content: any;
  created_at: string;
}