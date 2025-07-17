// Types pour l'application LiberTalk
export interface User {
  id: string;
  socketId: string;
  country?: string;
  language: string;
  isEuropean: boolean;
  partnerId?: string;
  lastActivity: number;
}

export interface ChatMessage {
  id: string;
  senderId: string;
  content: string;
  timestamp: number;
}

export interface MatchRequest {
  userId: string;
  preferences: {
    european: boolean;
    language?: string;
  };
}

export type Theme = 'light' | 'dark';
export type Language = 'en' | 'fr' | 'de' | 'es' | 'it';