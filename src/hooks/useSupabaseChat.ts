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
  
  // États explicites pour l'interface
  const [appState, setAppState] = useState<{
    phase: 'idle' | 'loading' | 'geolocation' | 'joining_queue' | 'searching' | 'matching' | 'confirming' | 'connected' | 'error';
    message: string;
    details?: string;
    canRetry?: boolean;
  }>({ phase: 'idle', message: '' });
  
  const { location, requestLocationNonBlocking, loading: locationLoading, error: locationError, isIPBased } = useGeolocation();
  const nextButtonTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const isActiveRef = useRef<boolean>(true);
  const retryTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const heartbeatRef = useRef<NodeJS.Timeout | null>(null);

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

  // Global error handler
  const handleError = useCallback((error: any, context: string, canRetry: boolean = true) => {
    console.error(`❌ Error in ${context}:`, error);
    
    // Log detailed error information
    if (error?.message) {
      console.error(`   Message: ${error.message}`);
    }
    if (error?.code) {
      console.error(`   Code: ${error.code}`);
    }
    if (error?.details) {
      console.error(`   Details: ${error.details}`);
    }
    if (error?.hint) {
      console.error(`   Hint: ${error.hint}`);
    }
    
    const errorMessage = error?.message || error?.toString() || 'Unknown error';
    
    setAppState({
      phase: 'error',
      message: `Connection error: ${errorMessage}`,
      details: `Context: ${context}`,
      canRetry
    });
    
    setConnectionError(`${context}: ${errorMessage}`);
    
    // Show browser alert for critical errors
    if (!canRetry || context.includes('Fatal')) {
      setTimeout(() => {
        alert(`LiberTalk Error: ${errorMessage}\n\nContext: ${context}\n\nPlease refresh the page.`);
      }, 100);
    }
    
    // Auto-retry après 3 secondes si possible
    if (canRetry && isActiveRef.current) {
      if (retryTimeoutRef.current) {
        clearTimeout(retryTimeoutRef.current);
      }
      retryTimeoutRef.current = setTimeout(() => {
        if (isActiveRef.current) {
          console.log('🔄 Auto-retry after error...');
          handleRetry();
        }
      }, 3000);
    }
  }, []);

  // Retry function
  const handleRetry = useCallback(() => {
    console.log('🔄 Manual retry initiated');
    setConnectionError(null);
    setAppState({ phase: 'idle', message: '' });
    
    if (retryTimeoutRef.current) {
      clearTimeout(retryTimeoutRef.current);
      retryTimeoutRef.current = null;
    }
    
    // Restart the connection process
    startChatWithLocation();
  }, []);

  // Handle realtime events with error handling
  const handleMessageReceived = useCallback((message: Message) => {
    if (!isActiveRef.current) return;
    try {
      console.log('📨 Message received:', message.content?.substring(0, 50) + '...');
      setMessages(prev => {
        if (prev.some(m => m.id === message.id)) return prev;
        return [...prev, message].sort((a, b) => 
          new Date(a.created_at).getTime() - new Date(b.created_at).getTime()
        );
      });
    } catch (error) {
      handleError(error, 'handleMessageReceived', false);
    }
  }, [handleError]);

  const handleUserDisconnected = useCallback(() => {
    if (!isActiveRef.current) return;
    try {
      console.log('🚪 Partner disconnected detected');
      setIsConnected(false);
      setPartnerId(null);
      setPartnerLocation(null);
      setAppState({ phase: 'idle', message: '' });
      
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
      handleError(error, 'handleUserDisconnected');
    }
  }, [currentChat, handleError]);

  const handleChatUpdate = useCallback((chat: any) => {
    if (!isActiveRef.current) return;
    try {
      console.log('💬 Chat updated:', chat.status);
      if (chat.status === 'ended') {
        handleUserDisconnected();
      }
    } catch (error) {
      handleError(error, 'handleChatUpdate', false);
    }
  }, [handleUserDisconnected, handleError]);

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
      handleError(error, 'handlePresenceUpdate', false);
    }
  }, [partnerId, isConnected, handleUserDisconnected, handleError]);

  // Handle match found from queue
  const handleBilateralMatchFound = useCallback((matchData: any) => {
    if (!isActiveRef.current) return;
    
    try {
      console.log('🎉 Match found from queue:', matchData);
      
      if (matchData.requires_confirmation && !matchData.both_confirmed) {
        console.log('⏳ Match requires bilateral confirmation...');
        setAppState({ 
          phase: 'confirming', 
          message: '🤝 Match found! Confirming connection...',
          details: 'Waiting for both users to confirm'
        });
      } else {
        console.log('✅ Match confirmed, activating chat');
        setAppState({ 
          phase: 'connected', 
          message: '✅ Connected! Starting chat...' 
        });
        handleMatchFound(matchData);
      }
      
    } catch (error) {
      handleError(error, 'handleBilateralMatchFound');
    }
  }, [handleError]);

  // Setup realtime subscriptions with error handling
  const { updatePresence, broadcastMessage, refreshSubscriptions } = useSupabaseRealtime({
    userId: currentUser?.id,
    chatId: currentChat?.chat_id,
    onMessageReceived: handleMessageReceived,
    onUserDisconnected: handleUserDisconnected,
    onPresenceUpdate: handlePresenceUpdate,
    onChatUpdate: handleChatUpdate,
    onBilateralMatchFound: handleBilateralMatchFound,
  });

  // Initialize user session with error handling
  const initializeUser = useCallback(async (locationData: any) => {
    if (!isActiveRef.current) return null;
    
    try {
      setConnectionError(null);
      console.log('🔧 Initializing user session with location:', locationData?.continent, locationData?.country);
      
      let deviceId;
      try {
        deviceId = localStorage.getItem('libertalk_device_id') || 
                   crypto.randomUUID?.() || 
                   Math.random().toString(36).substring(2);
        localStorage.setItem('libertalk_device_id', deviceId);
      } catch (storageError) {
        console.warn('⚠️ localStorage not available, using session-only ID');
        deviceId = crypto.randomUUID?.() || Math.random().toString(36).substring(2);
      }
      
      const userData = {
        id: deviceId,
        location: locationData?.latitude && locationData?.longitude 
          ? `POINT(${locationData.longitude} ${locationData.latitude})`
          : null,
        ip_geolocation: {
          continent: locationData?.continent || 'Unknown',
          country: locationData?.country || 'Unknown',
          city: locationData?.city || 'Unknown'
        },
        language,
        status: 'searching',
        connected_at: new Date().toISOString(),
        last_activity: new Date().toISOString(),
        session_token: crypto.randomUUID?.() || Math.random().toString(36).substring(2),
      };

      console.log('💾 Inserting user data:', userData);
      
      const { data, error } = await supabase
        .from('waiting_users')
        .upsert(userData, { onConflict: 'id' })
        .select()
        .single();

      }
      
      if (!data) {
        throw new Error('No data returned from user insert');
      if (error) throw error;
      
      console.log('✅ User session initialized successfully');
      setCurrentUser(data);
      
      try {
        await updatePresence('online');
      } catch (presenceError) {
        console.warn('⚠️ Failed to update presence, continuing anyway:', presenceError);
      }
      
      return data;
      
    } catch (error) {
      console.error('❌ initializeUser failed:', error);
      handleError(error, 'initializeUser', true);
      return null;
    }
  }, [language, updatePresence, handleError]);

  // Start heartbeat system
  const startHeartbeat = useCallback(() => {
    if (heartbeatRef.current) {
      clearInterval(heartbeatRef.current);
    }
    
    console.log('💓 Starting heartbeat system (10s interval)');
    heartbeatRef.current = setInterval(async () => {
      if (!isActiveRef.current || !currentUser) return;
      
      try {
        console.log('💓 Sending heartbeat ping...');
        const { error } = await supabase.rpc('send_heartbeat', { 
          p_user_id: currentUser.id,
          p_connection_quality: connectionQuality
        });
        
        if (error) {
          console.warn('💔 Heartbeat failed:', error.message);
          // Try to reconnect after 3 failed heartbeats
          handleDisconnectReconnect();
        } else {
          console.log('✅ Heartbeat successful');
        }
      } catch (error) {
        console.warn('💔 Heartbeat error:', error);
        handleDisconnectReconnect();
      }
    }, 10000); // Every 10 seconds
  }, [currentUser, connectionQuality, handleDisconnectReconnect]);

  // Start chat with comprehensive error handling
  const startChatWithLocation = useCallback(async () => {
    if (!isActiveRef.current) return;
    
    try {
      console.log('🚀 Starting chat initialization...');
      setIsConnecting(true);
      setConnectionError(null);
      setAppState({ 
        phase: 'loading', 
        message: '🚀 Starting chat...' 
      });

      // Step 1: Get location (non-blocking, 3s max)
      let locationData: any = null;
      try {
        setAppState({ 
          phase: 'geolocation', 
          message: '📍 Getting location for better matching (3s max)...' 
        });
        
        console.log('📍 Attempting geolocation (3s timeout)...');
        locationData = await requestLocationNonBlocking(3000);
        
        if (locationData) {
          console.log('✅ Geolocation success:', locationData.continent, locationData.country);
        } else {
          console.log('📍 Geolocation failed - proceeding with global matching');
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
      
      // Step 2: Initialize user session
      setAppState({ 
        phase: 'joining_queue', 
        message: '👤 Initializing user session...' 
      });

      const user = await initializeUser(locationData);
      if (!user) {
        throw new Error('Failed to initialize user session');
      }
      
      // Step 3: Join matching queue
      console.log('👤 User initialized, joining waiting queue...');
      setAppState({ 
        phase: 'joining_queue', 
        message: '🔄 Joining waiting queue...' 
      });
      
      try {
        await joinQueue(user.device_id, []);
      } catch (queueError) {
        console.error('❌ Failed to join queue:', queueError);
        throw new Error(`Queue join failed: ${queueError.message || queueError}`);
      }
      
      // Step 4: Start heartbeat system
      try {
        startHeartbeat();
      } catch (heartbeatError) {
        console.warn('⚠️ Failed to start heartbeat, continuing anyway:', heartbeatError);
      }
      
      console.log('✅ Chat initialization completed successfully');
      
    } catch (error) {
      console.error('❌ Error starting chat:', error);
      handleError(error, 'startChatWithLocation', true);
      setIsConnecting(false);
    }
  }, [requestLocationNonBlocking, initializeUser, joinQueue, startHeartbeat, handleError]);

  // Handle match found with error handling
  const handleMatchFound = useCallback(async (match: any) => {
    if (!isActiveRef.current) return;
    
    try {
      console.log('🎉 Processing successful match - activating chat');
      
      setIsConnecting(false);
      setIsConnected(true);
      setPartnerId(match.partner_id);
      setAppState({ 
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
        .from('waiting_users')
        .select('continent, country, city')
        .eq('id', match.partner_id)
        .single();

      if (partnerData && !partnerError) {
        console.log('👤 Partner info retrieved successfully');
        setPartnerLocation({
          continent: partnerData.continent,
          country: partnerData.country,
          city: partnerData.city
        });
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
      handleError(error, 'handleMatchFound');
    }
  }, [currentUser, handleError]);

  // Update app state based on queue state
  useEffect(() => {
    if (isInQueue && isSearching) {
      if (searchAttempts === 0) {
        setAppState({ 
          phase: 'searching', 
          message: '🔍 Searching for someone to chat with...',
          details: queuePosition !== null ? `Position in queue: ${queuePosition + 1}` : undefined
        });
      } else {
        const totalWaiting = queueStats?.total_waiting || 0;
        setAppState({ 
          phase: 'searching', 
          message: `🔍 Searching for the perfect match... (attempt ${searchAttempts})`,
          details: totalWaiting > 0 ? `${totalWaiting} users online` : 'You might be the first one here!'
        });
      }
    } else if (isInQueue && !isSearching) {
      setAppState({ 
        phase: 'searching', 
        message: '⏳ In queue, waiting for matching to start...' 
      });
    } else if (!isInQueue && !isConnected && appState.phase !== 'error') {
      setAppState({ phase: 'idle', message: '' });
    }
  }, [isInQueue, isSearching, searchAttempts, queueStats, queuePosition, appState.phase]);

  // Handle match found from queue
  useEffect(() => {
    if (matchResult?.success && matchResult.chat_id && matchResult.partner_id && currentUser && isActiveRef.current) {
      console.log('🎯 Processing successful match result');
      handleMatchFound(matchResult);
    }
  }, [matchResult, currentUser, handleMatchFound]);

  // Send message with error handling
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
        .from('waiting_users')
        .update({ last_heartbeat: new Date().toISOString() })
        .eq('id', currentUser.id);

    } catch (error) {
      handleError(error, 'sendMessage', false);
    }
  }, [currentChat, currentUser, broadcastMessage, handleError]);

  // Skip partner with error handling
  const skipPartner = useCallback(async () => {
    if (!currentChat || !currentUser || !isActiveRef.current) return;

    try {
      console.log('⏭️ Skipping partner...');
      
      const { error } = await supabase.rpc('end_chat_session', {
        p_user_id: currentUser.id,
        p_chat_id: currentChat.chat_id
      });
      
      if (error) {
        console.error('💾 Supabase insert error:', error);
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
      setAppState({ phase: 'idle', message: '' });

      // Rejoin queue for new match
      setTimeout(async () => {
        if (isActiveRef.current) {
          await joinQueue(currentUser.id, currentUser.previous_matches || []);
        }
      }, 500);
    } catch (error) {
      handleError(error, 'skipPartner');
    }
  }, [currentChat, currentUser, leaveQueue, joinQueue, handleError]);

  // Handle next button click
  const handleNextClick = useCallback(async () => {
    if (!isActiveRef.current) return;
    
    try {
      console.log('➡️ Next button clicked');
      setShowNextButton(false);
      setNextButtonCountdown(0);
      setAppState({ phase: 'idle', message: '' });
      
      if (currentUser) {
        // Small delay before rejoining
        setTimeout(() => {
          if (isActiveRef.current) {
            joinQueue(currentUser.id, currentUser.previous_matches || []);
          }
        }, 500);
      }
    } catch (error) {
      handleError(error, 'handleNextClick', false);
    }
  }, [currentUser, joinQueue, handleError]);

  // Disconnect with cleanup
  const disconnect = useCallback(async () => {
    console.log('🔌 Disconnecting...');
    isActiveRef.current = false;
    
    if (!currentUser) return;

    try {
      // Clear all timeouts
      [retryTimeoutRef, nextButtonTimeoutRef, heartbeatRef].forEach(ref => {
        if (ref.current) {
          clearTimeout(ref.current);
          ref.current = null;
        }
      });

      await leaveQueue();

      await supabase
        .from('waiting_users')
        .update({ 
          status: 'disconnected'
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
  }, [currentUser, currentChat, leaveQueue, updatePresence]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      console.log('🧹 Cleaning up chat hook');
      isActiveRef.current = false;
      disconnect();
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
    appState, // État explicite pour l'interface
    startChatWithLocation,
    sendMessage,
    skipPartner,
    handleNextClick,
    handleRetry, // Fonction retry pour l'interface
    disconnect,
    refreshSubscriptions,
  };
};