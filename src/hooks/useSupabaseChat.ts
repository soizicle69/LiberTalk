import { useState, useEffect, useCallback, useRef } from 'react';
import { supabase, User, Chat, Message } from '../lib/supabase';
import { useGeolocation } from './useGeolocation';
import { useSupabaseRealtime } from './useSupabaseRealtime';
import { useMatchingQueue } from './useMatchingQueue';

export const useSupabaseChat = (language: string) => {
  const [currentUser, setCurrentUser] = useState<User | null>(null);
  const [currentChat, setCurrentChat] = useState<Chat | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [isConnecting, setIsConnecting] = useState(false);
  const [isConnected, setIsConnected] = useState(false);
  const [partnerId, setPartnerId] = useState<string | null>(null);
  const [partnerLocation, setPartnerLocation] = useState<any>(null);
  const [connectionError, setConnectionError] = useState<string | null>(null);
  const [showNextButton, setShowNextButton] = useState(false);
  const [nextButtonCountdown, setNextButtonCountdown] = useState(0);
  const [searchStatus, setSearchStatus] = useState<{
    phase: 'idle' | 'joining' | 'searching' | 'matching' | 'confirming' | 'connected';
    message: string;
    details?: string;
  }>({ phase: 'idle', message: '' });
  
  const { location, requestLocation, loading: locationLoading, error: locationError, isIPBased } = useGeolocation();
  const nextButtonTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const isActiveRef = useRef<boolean>(true);

  // Use matching queue
  const {
    isInQueue,
    isSearching,
    waitTime,
    queueStats,
    matchResult,
    error: queueError,
    searchAttempts,
    connectionQuality,
    queuePosition,
    estimatedWait,
    joinQueue,
    leaveQueue,
    handleDisconnectReconnect,
  } = useMatchingQueue(language);

  // Handle realtime events
  const handleMessageReceived = useCallback((message: Message) => {
    if (!isActiveRef.current) return;
    try {
      setMessages(prev => {
        if (prev.some(m => m.id === message.id)) return prev;
        return [...prev, message].sort((a, b) => 
          new Date(a.created_at).getTime() - new Date(b.created_at).getTime()
        );
      });
      console.log('📨 Message received and added to state');
    } catch (error) {
      console.warn('Error handling received message:', error);
    }
  }, []);

  const handleUserDisconnected = useCallback(() => {
    if (!isActiveRef.current) return;
    try {
      console.log('🚪 Partner disconnected detected');
      setIsConnected(false);
      setPartnerId(null);
      setPartnerLocation(null);
      setSearchStatus({ phase: 'idle', message: '' });
      
      // Add system message
      const disconnectMessage: Message = {
        id: `disconnect-${Date.now()}`,
        chat_id: currentChat?.chat_id || 'system',
        sender_id: 'system',
        content: 'User disconnected',
        translated_content: {},
        created_at: new Date().toISOString(),
      };
      setMessages(prev => [...prev, disconnectMessage]);
      
      // Show "Next" button with 3s countdown
      setShowNextButton(true);
      setNextButtonCountdown(3);
      
      const countdownInterval = setInterval(() => {
        setNextButtonCountdown(prev => {
          if (prev <= 1) {
            clearInterval(countdownInterval);
            return 0;
          }
          return prev - 1;
        });
      }, 1000);
      
    } catch (error) {
      console.error('Error handling user disconnection:', error);
      handleDisconnectReconnect(); // Auto-reconnect on error
    }
  }, [currentChat]);

  const handleChatUpdate = useCallback((chat: any) => {
    if (!isActiveRef.current) return;
    try {
      if (chat.status === 'ended') {
        console.log('💬 Chat ended via update');
      }
    } catch (error) {
      console.warn('Error handling chat update:', error);
    }
  }, [handleUserDisconnected]);

  const handlePresenceUpdate = useCallback((presence: any) => {
    if (!isActiveRef.current) return;
    try {
      // Handle presence updates for connection monitoring
      if (presence?.type === 'leave' && partnerId && presence.key === partnerId) {
        console.log('🚪 Partner left presence, may have disconnected');
        // Don't immediately disconnect, wait for confirmation
        setTimeout(() => {
          if (isConnected && partnerId === presence.key) {
            handleUserDisconnected();
          }
        }, 10000); // 10 second grace period
      }
    } catch (error) {
      console.warn('Error handling presence update:', error);
    }
  }, [partnerId, isConnected, handleUserDisconnected]);

  // Handle match found from queue
  const handleBilateralMatchFound = useCallback((matchData: any) => {
    if (!isActiveRef.current) return;
    
    try {
      console.log('🎉 Match found from queue:', matchData);
      
      if (matchData.requires_confirmation && !matchData.both_confirmed) {
        console.log('⏳ Match requires bilateral confirmation...');
        setSearchStatus({ 
          phase: 'confirming', 
          message: '🤝 Match found! Confirming connection...',
          details: 'Waiting for both users to confirm'
        });
      } else {
        console.log('✅ Match confirmed, activating chat');
        setSearchStatus({ 
          phase: 'connected', 
          message: '✅ Connected! Starting chat...' 
        });
        handleMatchFound(matchData);
      }
      
    } catch (error) {
      console.error('❌ Error handling bilateral match:', error);
      handleDisconnectReconnect();
    }
  }, [handleDisconnectReconnect]);

  // Setup realtime subscriptions
  const { updatePresence, broadcastMessage, refreshSubscriptions } = useSupabaseRealtime({
    userId: currentUser?.id,
    chatId: currentChat?.chat_id,
    onMessageReceived: handleMessageReceived,
    onUserDisconnected: handleUserDisconnected,
    onPresenceUpdate: handlePresenceUpdate,
    onChatUpdate: handleChatUpdate,
    onBilateralMatchFound: handleBilateralMatchFound,
  });

  // Initialize user session
  const initializeUser = useCallback(async (locationData: any) => {
    if (!isActiveRef.current) return null;
    
    try {
      setConnectionError(null);
      console.log('🔧 Initializing user session with location:', locationData?.continent, locationData?.country);
      const deviceId = localStorage.getItem('libertalk_device_id') || 
                      crypto.randomUUID?.() || 
                      Math.random().toString(36).substring(2);
      localStorage.setItem('libertalk_device_id', deviceId);
      
      const userData = {
        ip_geolocation: {
          continent: locationData.continent || 'Unknown',
          country: locationData.country || 'Unknown',
          region: locationData.region || 'Unknown',
          city: locationData.city || 'Unknown',
          latitude: locationData.latitude || null,
          longitude: locationData.longitude || null,
        },
        continent: locationData.continent || 'Unknown',
        language,
        status: 'online',
        last_activity: new Date().toISOString(),
        connected_at: new Date().toISOString(),
        last_seen: new Date().toISOString(),
        device_id: deviceId,
        retry_count: 0,
      };

      console.log('💾 Inserting user data:', userData);
      
      const { data, error } = await supabase
        .from('active_users')
        .upsert(userData, { onConflict: 'device_id' })
        .select()
        .single();

      if (error) throw error;
      
      console.log('✅ User session initialized successfully');

      setCurrentUser(data);
      await updatePresence('online');
      return data;
    } catch (error) {
      console.error('Error initializing user:', error);
      setConnectionError('Failed to initialize user session. Please try again.');
      return null;
    }
  }, [language, updatePresence]);

  // Start chat with location
  const startChatWithLocation = useCallback(async () => {
    if (!isActiveRef.current) return;
    
    setIsConnecting(true);
    setConnectionError(null);
    setSearchStatus({ 
      phase: 'joining', 
      message: '🚀 Starting chat...' 
    });

    try {
      console.log('🚀 Starting chat initialization...');
      
      // Try to get location - completely non-blocking
      let locationData: any = null;
      try {
        setSearchStatus({ 
          phase: 'joining', 
          message: '📍 Getting location for better matching...' 
        });
        
        // Non-blocking location request with built-in timeout
        locationData = await requestLocationNonBlocking();
        
        if (locationData) {
          console.log('📍 Location obtained successfully:', locationData.continent, locationData.country);
        } else {
          console.log('📍 Location unavailable - proceeding with global matching');
        }
      } catch (geoError) {
        console.warn('📍 Geolocation error (non-blocking):', geoError);
        locationData = null;
      }
      
      // Always proceed regardless of location success/failure
      if (!locationData) {
        console.log('📍 Using global matching (no location data)');
        locationData = {
          continent: 'Unknown',
          country: 'Unknown',
          region: 'Unknown',
          city: 'Unknown',
        };
      }
      
      // Proceed to user initialization immediately
      setSearchStatus({ 
        phase: 'joining', 
        message: '👤 Initializing user session...' 
      });

      const user = await initializeUser(locationData);
      if (user) {
        console.log('👤 User initialized, joining waiting queue immediately...');
        setSearchStatus({ 
          phase: 'joining', 
          message: '🔄 Joining waiting queue...' 
        });
        // Join matching queue
        await joinQueue(user.id, user.previous_matches || []);
      } else {
        console.error('❌ Failed to initialize user');
        setConnectionError('Failed to initialize user session. Retrying...');
        setIsConnecting(false);
        setSearchStatus({ phase: 'idle', message: '' });
        setIsConnecting(false);
      }
    } catch (error) {
      console.error('Error starting chat:', error);
      setConnectionError('Failed to start chat. Please try again.');
      setIsConnecting(false);
      setSearchStatus({ phase: 'idle', message: '' });
      // Auto-retry after 2 seconds
      setTimeout(() => {
        if (isActiveRef.current) {
          console.log('🔄 Auto-retrying connection...');
          handleDisconnectReconnect();
        }
      }, 3000);
    }
  }, [requestLocationNonBlocking, initializeUser, joinQueue, handleDisconnectReconnect]);

  // Handle match found
  useEffect(() => {
    if (matchResult?.success && matchResult.chat_id && matchResult.partner_id && currentUser && isActiveRef.current) {
      console.log('🎯 Processing successful match result');
      handleMatchFound(matchResult);
    }
  }, [matchResult, currentUser, currentChat]);

  const handleMatchFound = useCallback(async (match: any) => {
    if (!isActiveRef.current) return;
    
    try {
      console.log('🎉 Processing successful match - activating chat');
      
      setIsConnecting(false);
      setIsConnected(true);
      setPartnerId(match.partner_id);
      setSearchStatus({ 
        phase: 'connected', 
        message: '✅ Connected! Chat is now active' 
      });
      setCurrentChat({ 
        chat_id: match.chat_id,
        user1_id: currentUser?.id,
        user2_id: match.partner_id,
        status: 'active'
      } as Chat);
      setMessages([]); // Clear previous messages
      
      // Get partner info
      console.log('👤 Fetching partner information...');
      const { data: partnerData, error: partnerError } = await supabase
        .from('active_users')
        .select('ip_geolocation')
        .eq('id', match.partner_id)
        .single();

      if (partnerData && !partnerError) {
        console.log('👤 Partner info retrieved successfully');
        setPartnerLocation(partnerData.ip_geolocation);
      } else {
        console.warn('⚠️ Failed to get partner info:', partnerError);
      }
      
      // Load existing messages
      console.log('📨 Loading chat history...');
      const { data: existingMessages, error: messagesError } = await supabase
        .from('chat_messages')
        .select('*')
        .eq('chat_id', match.chat_id)
        .order('created_at', { ascending: true });
      
      if (existingMessages && existingMessages.length > 0 && !messagesError) {
        console.log('📨 Loaded', existingMessages.length, 'existing messages');
        setMessages(existingMessages);
      } else if (messagesError) {
        console.warn('⚠️ Failed to load messages:', messagesError);
      }
      
      console.log('✅ Chat activation completed successfully');
      
    } catch (error) {
      console.error('Error handling match:', error);
      setConnectionError('Failed to process match. Please try again.');
      // Try to refresh subscriptions and reconnect
      refreshSubscriptions();
      setTimeout(() => {
        if (isActiveRef.current) {
          handleDisconnectReconnect();
        }
      }, 2000);
    }
  }, [refreshSubscriptions, handleDisconnectReconnect]);

  // Update search status based on queue state
  useEffect(() => {
    if (isInQueue && isSearching) {
      if (searchAttempts === 0) {
        setSearchStatus({ 
          phase: 'searching', 
          message: '🔍 Searching for someone to chat with...',
          details: queuePosition !== null ? `Position in queue: ${queuePosition + 1}` : undefined
        });
      } else {
        const totalWaiting = queueStats?.total_waiting || 0;
        setSearchStatus({ 
          phase: 'searching', 
          message: `🔍 Searching for the perfect match... (attempt ${searchAttempts})`,
          details: totalWaiting > 0 ? `${totalWaiting} users online` : 'You might be the first one here!'
        });
      }
    } else if (isInQueue && !isSearching) {
      setSearchStatus({ 
        phase: 'searching', 
        message: '⏳ In queue, waiting for matching to start...' 
      });
    } else if (!isInQueue && !isConnected) {
      setSearchStatus({ phase: 'idle', message: '' });
    }
  }, [isInQueue, isSearching, searchAttempts, queueStats, queuePosition]);
  // Send message
  const sendMessage = useCallback(async (content: string) => {
    if (!currentChat || !currentUser || !content.trim() || !isActiveRef.current) return;

    try {
      console.log('📤 Sending message:', content.substring(0, 50) + '...');
      
      const messageData = {
        chat_id: currentChat.chat_id,
        sender_id: currentUser.id,
        content: content.trim(),
      };

      const { data, error } = await supabase
        .from('chat_messages')
        .insert(messageData)
        .select()
        .single();

      if (error) throw error;

      console.log('✅ Message sent successfully');
      
      // Add message to local state immediately
      setMessages(prev => [...prev, data]);

      await broadcastMessage(data);

      // Update user activity
      await supabase
        .from('active_users')
        .update({ last_activity: new Date().toISOString() })
        .eq('id', currentUser.id);

    } catch (error) {
      console.error('Error sending message:', error);
      setConnectionError('Failed to send message. Please try again.');
      // Try to refresh connection
      refreshSubscriptions();
    }
  }, [currentChat, currentUser, broadcastMessage, refreshSubscriptions]);

  // Skip partner
  const skipPartner = useCallback(async () => {
    if (!currentChat || !currentUser || !isActiveRef.current) return;

    try {
      console.log('⏭️ Skipping partner...');
      
      const { error } = await supabase.rpc('end_chat_session', {
        p_user_id: currentUser.id,
        p_chat_id: currentChat.chat_id
      });
      
      if (error) {
        console.warn('⚠️ Error ending chat session:', error);
        // Fallback to direct update
        await supabase
        .from('chat_sessions')
        .update({ status: 'ended', ended_at: new Date().toISOString() })
        .eq('chat_id', currentChat.chat_id);
      }

      await leaveQueue();
      
      setCurrentChat(null);
      setPartnerId(null);
      setPartnerLocation(null);
      setIsConnected(false);
      setMessages([]);
      setShowNextButton(false);
      setNextButtonCountdown(0);
      setSearchStatus({ phase: 'idle', message: '' });

      // Rejoin queue for new match
      setTimeout(async () => {
        await joinQueue(currentUser.id, currentUser.previous_matches || []);
      }, 500);
    } catch (error) {
      console.error('Error skipping partner:', error);
      setConnectionError('Failed to skip partner. Please try again.');
      handleDisconnectReconnect();
    }
  }, [currentChat, currentUser, leaveQueue, joinQueue, handleDisconnectReconnect]);

  // Handle next button click
  const handleNextClick = useCallback(async () => {
    if (!isActiveRef.current) return;
    
    console.log('➡️ Next button clicked');
    setShowNextButton(false);
    setNextButtonCountdown(0);
    setSearchStatus({ phase: 'idle', message: '' });
    
    if (currentUser) {
      // Small delay before rejoining
      setTimeout(() => {
        joinQueue(currentUser.id, currentUser.previous_matches || []);
      }, 500);
    }
  }, [currentUser, joinQueue]);

  // Disconnect
  const disconnect = useCallback(async () => {
    console.log('🔌 Disconnecting...');
    isActiveRef.current = false;
    
    if (!currentUser) return;

    try {
      await leaveQueue();

      await supabase
        .from('active_users')
        .update({ 
          status: 'offline'
        })
        .eq('id', currentUser.id);

      if (currentChat) {
        await supabase.rpc('end_chat_session', {
          p_user_id: currentUser.id,
          p_chat_id: currentChat.chat_id
        });
      }

      await updatePresence('offline');
      
      console.log('✅ Disconnected successfully');
    } catch (error) {
      console.error('Error disconnecting:', error);
    }
  }, [currentUser, currentChat, leaveQueue, updatePresence, handleDisconnectReconnect]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      console.log('🧹 Cleaning up chat hook');
      isActiveRef.current = false;
      disconnect();
      if (nextButtonTimeoutRef.current) {
        clearTimeout(nextButtonTimeoutRef.current);
      }
    };
  }, [disconnect]);

  // Handle page visibility changes
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (document.hidden) {
        console.log('👁️ Page hidden - reducing activity');
      } else {
        console.log('👁️ Page visible - resuming activity');
        if (currentUser && isActiveRef.current) {
          updatePresence('online');
        }
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);
    return () => document.removeEventListener('visibilitychange', handleVisibilityChange);
  }, [currentUser, updatePresence]);

  return {
    currentUser,
    currentChat,
    messages,
    isConnecting: isConnecting || isInQueue,
    isConnected,
    partnerId,
    location,
    partnerLocation,
    locationError,
    locationLoading,
    isIPBased,
    connectionError: connectionError || queueError,
    searchAttempts,
    connectionQuality,
    queuePosition,
    estimatedWait,
    waitTime,
    queueStats,
    showNextButton,
    nextButtonCountdown,
    searchStatus,
    startChatWithLocation,
    sendMessage,
    skipPartner,
    handleNextClick,
    disconnect,
    refreshSubscriptions,
  };
};