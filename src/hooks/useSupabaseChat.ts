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

  // Global error handler - moved to top to be available for all functions
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

  // Use matching queue - moved before functions that depend on it
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

  // Skip partner with error handling (moved before handleUserDisconnected)
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
      
      // Show "Next" button with 5s countdown, then auto-skip
      setShowNextButton(true);
      setNextButtonCountdown(5);
      
      const countdownInterval = setInterval(() => {
        setNextButtonCountdown(prev => {
          if (prev <= 1) {
            clearInterval(countdownInterval);
            // Auto-skip partner after countdown
            console.log('⏭️ Auto-skipping partner after countdown');
            setTimeout(() => {
              if (isActiveRef.current && showNextButton) {
                skipPartner();
              }
            }, 100);
            return 0;
          }
          return prev - 1;
        });
      }, 1000);
      
    } catch (error) {
      handleError(error, 'handleUserDisconnected');
    }
  }, [currentChat, handleError, showNextButton, skipPartner]);

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
                   (typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : null) ||
                   Math.random().toString(36).substring(2);
        localStorage.setItem('libertalk_device_id', deviceId);
      } catch (storageError) {
        console.warn('⚠️ localStorage not available, using session-only ID');
        deviceId = (typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : null) ||
                   Math.random().toString(36).substring(2);
      }
      
      const userData = {
        p_device_id: deviceId,
        p_continent: locationData?.continent || 'Unknown',
        p_country: locationData?.country || 'Unknown',
        p_city: locationData?.city || 'Unknown',
        p_language: language,
        p_latitude: locationData?.latitude || null,
        p_longitude: locationData?.longitude || null,
        p_user_agent: navigator.userAgent,
        p_ip_address: null // Will be detected server-side
      };

      console.log('💾 Inserting user data:', userData);
      
      const { data, error } = await supabase.rpc('join_waiting_queue_v2', userData);

      if (error) throw error;

      // Log detailed response for debugging
      console.log('🔍 RPC Response data:', data);
      console.log('🔍 RPC Response type:', typeof data);
      console.log('🔍 RPC Response keys:', data ? Object.keys(data) : 'null');
      
      if (!data) {
        throw new Error('No data returned from join_waiting_queue_v2 RPC call');
      }
      
      if (!data.success) {
        const errorMsg = data.error || data.message || 'Failed to join queue - unknown error';
        console.error('🔍 RPC returned failure:', errorMsg);
        console.error('🔍 Full RPC response:', JSON.stringify(data, null, 2));
        throw new Error(`RPC Error: ${errorMsg}`);
      }
      
      if (!data.user_id) {
        console.error('🔍 Missing user_id in response:', JSON.stringify(data, null, 2));
        throw new Error('RPC returned success but missing user_id');
      }
      
      if (!data.session_id) {
        console.error('🔍 Missing session_id in response:', JSON.stringify(data, null, 2));
        throw new Error('RPC returned success but missing session_id');
      }
      
      console.log('✅ User session initialized successfully');
      
      // Create user object from response
      const userObject = {
        id: data.user_id,
        device_id: deviceId,
        session_token: data.session_id,
        continent: locationData?.continent || 'Unknown',
        country: locationData?.country || 'Unknown',
        city: locationData?.city || 'Unknown',
        language,
        status: 'searching',
        connected_at: new Date().toISOString(),
        last_activity: new Date().toISOString(),
      };
      
      setCurrentUser(userObject);
      
      try {
        await updatePresence('online');
      } catch (presenceError) {
        console.warn('⚠️ Failed to update presence, continuing anyway:', presenceError);
      }
      
      return userObject;
      
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
      console.log('🚀 FORCED START: Starting chat initialization (will proceed regardless)...');
      setIsConnecting(true);
      setConnectionError(null);
      setAppState({ 
        phase: 'loading', 
        message: '🚀 FORCED START: Starting chat (will proceed regardless)...' 
      });

      // Step 1: FORCED location (non-blocking, 2s max, will proceed regardless)
      let locationData: any = null;
      try {
        setAppState({ 
          phase: 'geolocation', 
          message: '📍 FORCED LOCATION: Getting location (2s max, will proceed regardless)...' 
        });
        
        console.log('📍 FORCED LOCATION: Attempting geolocation (2s timeout, will proceed regardless)...');
        locationData = await requestLocationNonBlocking(2000);
        
        if (locationData) {
          console.log('✅ FORCED SUCCESS: Geolocation success:', locationData.continent, locationData.country);
        } else {
          console.log('📍 FORCED PROGRESSION: Geolocation failed - proceeding with global matching');
        }
      } catch (geoError) {
        console.warn('📍 FORCED PROGRESSION: Geolocation error (non-blocking, proceeding anyway):', geoError);
        locationData = null;
      }
      
      // FORCED progression regardless of location success/failure
      if (!locationData) {
        console.log('📍 FORCED GLOBAL: Using global matching (no location data)');
        locationData = {
          continent: 'Unknown',
          country: 'Unknown',
          region: 'Unknown',
          city: 'Unknown',
        };
      }
      
      // Handle location error but proceed anyway
      if (locationError) {
        console.log('📍 FORCED PROGRESSION: Location error detected, setting null and proceeding:', locationError);
        locationData = null;
        setAppState({ 
          phase: 'joining_queue', 
          message: '📍 FORCED PROGRESSION: Location unavailable, using global matching...' 
        });
      }
      
      // Step 2: FORCED user session initialization
      setAppState({ 
        phase: 'joining_queue', 
        message: '👤 FORCED INIT: Initializing user session (will retry on fail)...' 
      });

      const user = await initializeUser(locationData);
      if (!user) {
        console.error('❌ FORCED RETRY: Failed to initialize user session, will retry...');
        // Force retry instead of throwing
        setTimeout(() => {
          if (isActiveRef.current) {
            console.log('🔄 FORCED RETRY: Auto-retrying user initialization...');
            startChatWithLocation();
          }
        }, 2000);
        return;
      }
      
      // Step 3: FORCED queue join
      console.log('👤 FORCED QUEUE: User initialized, joining waiting queue (will retry on fail)...');
      setAppState({ 
        phase: 'joining_queue', 
        message: '🔄 FORCED QUEUE: Joining waiting queue (will retry on fail)...' 
      });
      
      try {
        await joinQueue(user.device_id, [], locationData);
      } catch (queueError) {
        console.error('❌ FORCED RETRY: Failed to join queue, will auto-retry:', queueError);
        // Force retry instead of giving up
        setTimeout(() => {
          if (isActiveRef.current) {
            console.log('🔄 FORCED RETRY: Auto-retrying queue join...');
            startChatWithLocation();
          }
        }, 2000);
        return;
      }
      
      // Step 4: FORCED heartbeat system
      try {
        startHeartbeat();
      } catch (heartbeatError) {
        console.warn('⚠️ FORCED CONTINUE: Failed to start heartbeat, continuing anyway:', heartbeatError);
      }
      
      console.log('✅ FORCED SUCCESS: Chat initialization completed successfully');
      
    } catch (error) {
      console.error('❌ FORCED RETRY: Error starting chat, will auto-retry:', error);
      // Force retry instead of just showing error
      setIsConnecting(false);
      setTimeout(() => {
        if (isActiveRef.current) {
          console.log('🔄 FORCED RETRY: Auto-retrying chat initialization...');
          startChatWithLocation();
        }
      }, 3000);
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
    // Show progress during searching with spinner/timer
    if (isInQueue && isSearching) {
      const minutes = Math.floor(waitTime / 60);
      const seconds = waitTime % 60;
      const timeDisplay = `${minutes}:${seconds.toString().padStart(2, '0')}`;
      
      if (searchAttempts === 0) {
        setAppState({ 
          phase: 'searching', 
          message: `🔍 FORCED SEARCH: Searching for someone to chat with... (${timeDisplay})`,
          details: queuePosition !== null ? `Position: ${queuePosition + 1} | ${queueStats?.total_waiting || 0} users online` : `${queueStats?.total_waiting || 0} users online`
        });
      } else {
        const totalWaiting = queueStats?.total_waiting || 0;
        setAppState({ 
          phase: 'searching', 
          message: `🔍 FORCED SEARCH: Finding perfect match... (${timeDisplay} | attempt ${searchAttempts})`,
          details: totalWaiting > 0 ? `${totalWaiting} users online | Quality: ${connectionQuality}%` : 'You might be the first one here!'
        });
      }
    } else if (isInQueue && !isSearching) {
      setAppState({ 
        phase: 'joining_queue', 
        message: '⏳ FORCED QUEUE: In queue, starting matching soon...',
        details: 'Preparing search algorithm...'
      });
    } else if (!isInQueue && !isConnected && appState.phase !== 'error') {
      setAppState({ phase: 'idle', message: '' });
    }
  }, [isInQueue, isSearching, searchAttempts, queueStats, queuePosition, appState.phase, waitTime, connectionQuality]);

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
    // Handle page unload/refresh
    const handleBeforeUnload = () => {
      console.log('🔌 Page unloading, disconnecting...');
      isActiveRef.current = false;
      if (currentUser) {
        // Synchronous disconnect for page unload
        navigator.sendBeacon?.('/api/disconnect', JSON.stringify({ userId: currentUser.id })) ||
        fetch('/api/disconnect', { 
          method: 'POST', 
          body: JSON.stringify({ userId: currentUser.id }),
          keepalive: true 
        }).catch(() => {});
      }
    };
    
    window.addEventListener('beforeunload', handleBeforeUnload);
    
    return () => {
      console.log('🧹 Cleaning up chat hook');
      window.removeEventListener('beforeunload', handleBeforeUnload);
      isActiveRef.current = false;
      disconnect();
    };
  }, [disconnect, currentUser]);

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