import { useState, useEffect, useCallback, useRef } from 'react';
import { supabase } from '../lib/supabase';
import { useGeolocation } from './useGeolocation';

interface QueueStats {
  total_waiting: number;
  by_continent: Record<string, number>;
  by_language: Record<string, number>;
  average_wait_time: number;
  timestamp: string;
}

interface MatchResult {
  success: boolean;
  match_id?: string;
  partner_id?: string;
  partner_info?: {
    continent: string;
    country: string;
    city: string;
    language: string;
  };
  chat_id?: string;
  match_score?: number;
  distance_km?: number;
  requires_confirmation?: boolean;
  confirmation_timeout?: number;
  message: string;
  error?: string;
  retry_in_seconds?: number;
  both_confirmed?: boolean;
}

export const useMatchingQueue = (language: string) => {
  const [isInQueue, setIsInQueue] = useState(false);
  const [isSearching, setIsSearching] = useState(false);
  const [waitTime, setWaitTime] = useState(0);
  const [queueStats, setQueueStats] = useState<QueueStats | null>(null);
  const [matchResult, setMatchResult] = useState<MatchResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [searchAttempts, setSearchAttempts] = useState(0);
  const [connectionQuality, setConnectionQuality] = useState(100);
  const [queuePosition, setQueuePosition] = useState<number | null>(null);
  const [estimatedWait, setEstimatedWait] = useState<number | null>(null);
  
  const { location, requestLocation } = useGeolocation();
  const searchIntervalRef = useRef<NodeJS.Timeout | null>(null);
  const waitTimeIntervalRef = useRef<NodeJS.Timeout | null>(null);
  const heartbeatIntervalRef = useRef<NodeJS.Timeout | null>(null);
  const statsIntervalRef = useRef<NodeJS.Timeout | null>(null);
  const cleanupIntervalRef = useRef<NodeJS.Timeout | null>(null);
  const currentUserIdRef = useRef<string | null>(null);
  const currentSessionIdRef = useRef<string | null>(null);
  const isActiveRef = useRef<boolean>(false);
  const deviceIdRef = useRef<string>('');
  const bilateralTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  // Initialize device ID
  useEffect(() => {
    const deviceId = localStorage.getItem('libertalk_device_id') || 
                    crypto.randomUUID?.() || 
                    Math.random().toString(36).substring(2);
    localStorage.setItem('libertalk_device_id', deviceId);
    deviceIdRef.current = deviceId;
    console.log('🔧 Device ID initialized:', deviceId);
  }, []);

  // Start wait timer with detailed logging
  const startWaitTimer = useCallback(() => {
    console.log('⏱️ Starting wait timer for queue');
    setWaitTime(0);
    if (waitTimeIntervalRef.current) {
      clearInterval(waitTimeIntervalRef.current);
    }
    waitTimeIntervalRef.current = setInterval(() => {
      setWaitTime(prev => {
        const newTime = prev + 1;
        if (newTime % 15 === 0) {
          console.log(`⏳ Waiting in queue for ${Math.floor(newTime / 60)}:${(newTime % 60).toString().padStart(2, '0')}`);
        }
        return newTime;
      });
    }, 1000);
  }, []);

  // Stop wait timer
  const stopWaitTimer = useCallback(() => {
    console.log('⏹️ Stopping wait timer');
    if (waitTimeIntervalRef.current) {
      clearInterval(waitTimeIntervalRef.current);
      waitTimeIntervalRef.current = null;
    }
    setWaitTime(0);
  }, []);

  // Enhanced heartbeat with connection quality monitoring
  const sendHeartbeat = useCallback(async (userId: string) => {
    if (!isActiveRef.current) return;
    
    try {
      const startTime = Date.now();
      const { data, error } = await supabase.rpc('send_heartbeat_v2', { 
        p_user_id: userId,
        p_connection_quality: connectionQuality
      });

      const responseTime = Date.now() - startTime;
      
      if (error) {
        console.warn('💔 Heartbeat failed:', error.message);
        setConnectionQuality(prev => Math.max(prev - 15, 0));
      } else {
        // Update connection quality based on response time
        const newQuality = responseTime < 100 ? 100 : 
                          responseTime < 300 ? 90 :
                          responseTime < 500 ? 80 :
                          responseTime < 1000 ? 70 : 50;
        setConnectionQuality(prev => Math.min(prev + 2, newQuality));
        
        if (Math.random() < 0.1) { // Log every 10th heartbeat
          console.log('💓 Heartbeat sent successfully, quality:', newQuality, 'response time:', responseTime + 'ms');
        }
      }
    } catch (error) {
      console.warn('💔 Heartbeat error:', error);
      setConnectionQuality(prev => Math.max(prev - 20, 0));
    }
  }, [connectionQuality]);

  // Update queue statistics with enhanced logging
  const updateQueueStats = useCallback(async () => {
    if (!isActiveRef.current) return;
    
    try {
      const { data, error } = await supabase.rpc('get_queue_statistics_v2');
      if (error) {
        console.warn('📊 Failed to update queue stats:', error.message);
        return;
      }
      
      if (data && isActiveRef.current) {
        setQueueStats(data);
        if (data.total_waiting !== queueStats?.total_waiting) {
          console.log('📊 Queue stats updated:', {
            total: data.total_waiting,
            continents: Object.keys(data.by_continent || {}).length,
            languages: Object.keys(data.by_language || {}).length,
            avgWait: Math.round(data.average_wait_time) + 's'
          });
        }
      }
    } catch (error) {
      console.warn('📊 Queue stats error:', error);
    }
  }, [queueStats?.total_waiting]);

  // Cleanup inactive sessions
  const runCleanup = useCallback(async () => {
    if (!isActiveRef.current) return;
    
    try {
      const { data, error } = await supabase.rpc('cleanup_inactive_sessions_v2');
      if (error) {
        console.warn('🧹 Cleanup failed:', error.message);
      } else if (data && (data.cleaned_users > 0 || data.cleaned_sessions > 0)) {
        console.log('🧹 Cleanup completed:', {
          users: data.cleaned_users,
          sessions: data.cleaned_sessions,
          matches: data.cleaned_matches
        });
      }
    } catch (error) {
      console.warn('🧹 Cleanup error:', error);
    }
  }, []);

  // Start maintenance intervals with staggered timing
  const startMaintenanceIntervals = useCallback((userId: string, sessionId: string) => {
    console.log('🔄 Starting maintenance intervals for user:', userId);
    
    // Heartbeat every 5 seconds (critical for connection)
    if (heartbeatIntervalRef.current) {
      clearInterval(heartbeatIntervalRef.current);
    }
    heartbeatIntervalRef.current = setInterval(() => {
      if (isActiveRef.current) {
        sendHeartbeat(userId);
      }
    }, 5000);

    // Stats every 8 seconds (offset from heartbeat)
    if (statsIntervalRef.current) {
      clearInterval(statsIntervalRef.current);
    }
    setTimeout(() => {
      statsIntervalRef.current = setInterval(() => {
        if (isActiveRef.current) {
          updateQueueStats();
        }
      }, 8000);
    }, 2000);

    // Cleanup every 30 seconds (offset from others)
    if (cleanupIntervalRef.current) {
      clearInterval(cleanupIntervalRef.current);
    }
    setTimeout(() => {
      cleanupIntervalRef.current = setInterval(() => {
        if (isActiveRef.current) {
          runCleanup();
        }
      }, 30000);
    }, 5000);
  }, [sendHeartbeat, updateQueueStats, runCleanup]);

  // Stop all intervals
  const stopAllIntervals = useCallback(() => {
    console.log('🛑 Stopping all maintenance intervals');
    [searchIntervalRef, waitTimeIntervalRef, heartbeatIntervalRef, 
     statsIntervalRef, cleanupIntervalRef, bilateralTimeoutRef].forEach(ref => {
      if (ref.current) {
        clearInterval(ref.current);
        ref.current = null;
      }
    });
  }, []);

  // Join queue with enhanced error handling and logging
  const joinQueue = useCallback(async (userId?: string, previousMatches: string[] = [], forceLocation: any = null) => {
    if (isInQueue && !userId) {
      console.log('🔄 Already in queue, skipping join...');
      return;
    }

    try {
      console.log('🚀 FORCED QUEUE JOIN: Starting immediately regardless of location status');
      setError(null);
      setIsInQueue(true);
      setIsSearching(true);
      setSearchAttempts(0);
      setMatchResult(null);
      setQueuePosition(null);
      setEstimatedWait(null);
      isActiveRef.current = true;
      
      console.log('🚀 FORCED JOIN: Joining waiting queue with device:', deviceIdRef.current);

      // FORCE progression with location data (use provided, current, or fallback)
      const locationData = forceLocation || location || {
        continent: 'Unknown',
        country: 'Unknown', 
        city: 'Unknown',
        latitude: null,
        longitude: null
      };
      
      console.log('📍 FORCED LOCATION: Using location data (forced progression):', locationData.continent, locationData.country, locationData.city);

      // Join waiting queue
      let data, error;
      try {
        console.log('📡 FORCED RPC: Calling join_waiting_queue_v2 (will retry on fail)...');
        const result = await supabase.rpc('join_waiting_queue_v2', {
          p_device_id: deviceIdRef.current,
          p_continent: locationData?.continent || 'Unknown',
          p_country: locationData?.country || 'Unknown',
          p_city: locationData?.city || 'Unknown',
          p_language: language,
          p_latitude: locationData?.latitude || null,
          p_longitude: locationData?.longitude || null,
          p_user_agent: navigator.userAgent,
          p_ip_address: null
        });
        data = result.data;
        error = result.error;
      } catch (rpcError) {
        console.error('📡 FORCED RETRY: RPC call failed, will retry:', rpcError);
        // Force retry after 2s instead of throwing
        setTimeout(() => {
          if (isActiveRef.current) {
            console.log('🔄 FORCED RETRY: Auto-retrying queue join...');
            joinQueue(userId, previousMatches, locationData);
          }
        }, 2000);
        return;
      }

      if (error) {
        console.error('📡 FORCED RETRY: RPC returned error, will retry:', error);
        // Force retry instead of throwing
        setTimeout(() => {
          if (isActiveRef.current) {
            console.log('🔄 FORCED RETRY: Auto-retrying after RPC error...');
            joinQueue(userId, previousMatches, locationData);
          }
        }, 2000);
        return;
      }

      if (!data?.success) {
        console.error('📡 FORCED RETRY: RPC returned failure, will retry:', data);
        // Force retry instead of throwing
        setTimeout(() => {
          if (isActiveRef.current) {
            console.log('🔄 FORCED RETRY: Auto-retrying after RPC failure...');
            joinQueue(userId, previousMatches, locationData);
          }
        }, 2000);
        return;
      }

      console.log('✅ FORCED SUCCESS: Successfully joined waiting queue:', {
        userId: data.user_id,
        sessionId: data.session_id,
        position: data.queue_position,
        estimatedWait: data.estimated_wait_seconds + 's'
      });

      currentUserIdRef.current = data.user_id;
      currentSessionIdRef.current = data.session_id;
      setQueuePosition(data.queue_position);
      setEstimatedWait(data.estimated_wait_seconds);
      
      // Start timers and intervals
      startWaitTimer();
      startMaintenanceIntervals(data.user_id, data.session_id);
      
      // Start search process immediately
      console.log('🔍 FORCED SEARCH: Starting immediate search process...');
      if (isActiveRef.current) {
        startSearchProcess(data.user_id);
      }
      
      // Initial stats update
      try {
        updateQueueStats();
      } catch (statsError) {
        console.warn('⚠️ Failed to update queue stats, continuing anyway:', statsError);
      }
      
    } catch (error: any) {
      console.error('❌ FORCED RETRY: Error joining queue, will auto-retry:', error);
      const errorMessage = error?.message || error?.toString() || 'Unknown queue error';
      setError(`Retrying queue join: ${errorMessage}`);
      
      // FORCED auto-retry after 2 seconds on any failure
      setTimeout(() => {
        if (isActiveRef.current) {
          console.log('🔄 FORCED RETRY: Auto-retrying queue join after error...');
          joinQueue(userId, previousMatches, forceLocation);
        }
      }, 2000);
    }
  }, [location, language, startWaitTimer, startMaintenanceIntervals, updateQueueStats]);

  // Enhanced search process with intelligent retry logic
  const startSearchProcess = useCallback((userId: string) => {
    let attemptCount = 0;
    let consecutiveFailures = 0;
    const maxConsecutiveFailures = 5; // Cap at 5 failures
    const forceGlobalTimeout = 30000; // 30s timeout for global fallback
    let searchInterval: NodeJS.Timeout | null = null;
    const searchStartTime = Date.now();
    
    const performSearch = async () => {
      if (!isActiveRef.current) {
        console.log('🛑 FORCED STOP: Search stopped - not active');
        if (searchInterval) {
          clearInterval(searchInterval);
          searchInterval = null;
        }
        return;
      }

      // FORCE global random match after timeout
      const elapsedTime = Date.now() - searchStartTime;
      if (elapsedTime > forceGlobalTimeout) {
        console.log('⏰ FORCED GLOBAL: 30s timeout reached, forcing global random match...');
        setError('🌍 Expanding search globally for faster matching...');
        attemptCount = 0; // Reset counter
        consecutiveFailures = 0; // Reset failures
      }

      try {
        attemptCount++;
        setSearchAttempts(attemptCount);
        console.log(`🔍 FORCED SEARCH: Attempt ${attemptCount} for user ${userId} (${Math.round(elapsedTime/1000)}s elapsed)`);
        
        let data, error;
        try {
          console.log('📡 FORCED MATCH: Calling find_best_match_v2 RPC...');
          const result = await supabase.rpc('find_best_match_v2', {
            p_user_id: userId
          });
          data = result.data;
          error = result.error;
        } catch (rpcError) {
          console.error('📡 FORCED CONTINUE: Match RPC call failed, continuing search:', rpcError);
          consecutiveFailures++;
          // Don't throw, just continue with retry logic
          data = { success: false, error: rpcError.message || 'RPC failed' };
          error = null;
        }

        if (error) {
          console.error('📡 FORCED CONTINUE: Match RPC returned error, continuing search:', error);
          consecutiveFailures++;
          // Don't throw, just continue with retry logic
        }

        if (data?.success && data.match_id && data.partner_id && isActiveRef.current) {
          console.log('🎉 FORCED SUCCESS: Match found! Starting bilateral confirmation:', {
            matchId: data.match_id,
            partnerId: data.partner_id,
            score: data.match_score,
            distance: data.distance_km ? data.distance_km + 'km' : 'unknown'
          });
          
          consecutiveFailures = 0;
          setIsSearching(false);
          
          // Clear search interval
          if (searchInterval) {
            clearInterval(searchInterval);
            searchInterval = null;
          }
          
          // Start bilateral confirmation process
          try {
            startBilateralConfirmation(userId, data);
          } catch (confirmError) {
            console.error('❌ Failed to start bilateral confirmation:', confirmError);
            throw confirmError;
          }
          return;
        }

        // No match found - FORCE continue searching
        if (isActiveRef.current) {
          consecutiveFailures = 0; // Reset on successful search (even if no match)
          
          // FORCED faster retry for better responsiveness
          const retryDelay = Math.min(1500 + (attemptCount * 100), 3000); // 1.5-3s max
          
          console.log(`⏳ FORCED RETRY: No match found, retrying in ${retryDelay/1000}s (attempt ${attemptCount})`);
          
          if (data?.total_waiting === 0) {
            setError('🔍 FORCED SEARCH: Looking for someone to chat with... You might be the first one here!');
          } else {
            setError(`🔍 FORCED SEARCH: Finding the perfect match... ${data?.total_waiting || 0} users online`);
          }
          
          // FORCE global after many attempts
          if (attemptCount >= 20) { // After many attempts
            console.log('⏰ FORCED GLOBAL: Many attempts reached, forcing global random match...');
            setError('🌍 FORCED GLOBAL: Expanding search globally...');
            attemptCount = 0; // Reset counter
          }
          
          setTimeout(() => {
            if (isActiveRef.current) {
              performSearch();
            }
          }, retryDelay);
        }

      } catch (error: any) {
        console.error('❌ FORCED CONTINUE: Search attempt failed, continuing anyway:', error);
        consecutiveFailures++;
        
        // CAP consecutive failures at 5
        if (consecutiveFailures > maxConsecutiveFailures) {
          console.log('🔄 FORCED RESET: Too many consecutive failures, resetting and forcing global search...');
          consecutiveFailures = 0;
          attemptCount = 0;
          setError('🌍 FORCED GLOBAL: Switching to global search for better results...');
        }
        
        const errorMessage = error?.message || error?.toString() || 'Unknown search error';
        
        if (isActiveRef.current) {
          // FORCED faster backoff for better user experience
          const backoffDelay = Math.min(1000 * Math.pow(1.1, Math.min(consecutiveFailures, maxConsecutiveFailures)), 3000);
          console.log(`🔄 FORCED RETRY: Retrying search in ${backoffDelay/1000}s (failure ${consecutiveFailures}/${maxConsecutiveFailures})`);
          
          setError(`🔄 FORCED RETRY: Search continuing... (${errorMessage})`);
          
          setTimeout(() => {
            if (isActiveRef.current) {
              performSearch();
            }
          }, backoffDelay);
        }
      }
    };

    // Start first search attempt immediately
    console.log('🚀 FORCED START: Starting immediate search process...');
    try {
      performSearch();
    } catch (searchError) {
      console.error('❌ FORCED CONTINUE: Failed to start search process, will retry:', searchError);
      setError(`FORCED RETRY: Starting search... (${searchError.message || searchError})`);
      // Force retry instead of giving up
      setTimeout(() => {
        if (isActiveRef.current) {
          performSearch();
        }
      }, 2000);
    }
    
    // FORCED periodic polling every 1.5s as backup
    searchInterval = setInterval(() => {
      if (isActiveRef.current && isSearching) {
        console.log('🔄 FORCED POLL: Periodic search poll...');
        try {
          performSearch();
        } catch (pollError) {
          console.error('❌ FORCED CONTINUE: Periodic search poll failed, continuing:', pollError);
        }
      } else if (!isActiveRef.current || !isSearching) {
        if (searchInterval) {
          clearInterval(searchInterval);
          searchInterval = null;
        }
      }
    }, 1500); // Faster polling
    
    // Cleanup function
    return () => {
      if (searchInterval) {
        clearInterval(searchInterval);
        searchInterval = null;
      }
    };
  }, []);

  // Bilateral confirmation process with timeout handling
  const startBilateralConfirmation = useCallback((userId: string, matchData: any) => {
    console.log('⏳ Starting bilateral confirmation process');
    setError('🤝 Match found! Confirming connection...');
    
    let confirmAttempts = 0;
    const maxConfirmAttempts = 10;
    
    const confirmMatch = async () => {
      try {
        confirmAttempts++;
        console.log(`🤝 Confirmation attempt ${confirmAttempts}/${maxConfirmAttempts}`);
        
        const { data, error } = await supabase.rpc('confirm_bilateral_match_v2', {
          p_user_id: userId,
          p_match_id: matchData.match_id
        });

        if (error) {
          throw new Error(`Confirmation failed: ${error.message}`);
        }

        if (data?.success && data.both_confirmed && data.chat_id) {
          console.log('✅ Bilateral confirmation successful! Chat is active:', {
            chatId: data.chat_id,
            partnerId: data.partner_id
          });
          
          setMatchResult({
            success: true,
            match_id: matchData.match_id,
            partner_id: data.partner_id,
            partner_info: matchData.partner_info,
            chat_id: data.chat_id,
            match_score: matchData.match_score,
            distance_km: matchData.distance_km,
            both_confirmed: true,
            message: 'Connection established successfully!'
          });
          
          setIsInQueue(false);
          setIsSearching(false);
          stopWaitTimer();
          stopAllIntervals();
          setError(null);
          isActiveRef.current = false;
          return;
        }

        if (data?.success && !data.both_confirmed) {
          console.log(`⏳ Waiting for partner confirmation... (${confirmAttempts}/${maxConfirmAttempts})`);
          setError('⏳ Waiting for partner to confirm connection...');
          
          // Continue waiting for partner confirmation with attempt limit
          if (confirmAttempts < maxConfirmAttempts) {
            setTimeout(() => {
              if (isActiveRef.current) {
                confirmMatch();
              }
            }, 1000); // Poll every 1 second
          } else {
            console.log('⏰ Max confirmation attempts reached, restarting search...');
            setError('⏰ Partner confirmation timeout, searching for another match...');
            
            // Fallback to re-search
            setTimeout(() => {
              if (isActiveRef.current) {
                setIsSearching(true);
                startSearchProcess(userId);
              }
            }, 2000);
          }
          return;
        }

        throw new Error(data?.error || 'Confirmation failed');

      } catch (error: any) {
        console.error('❌ Bilateral confirmation failed:', error);
        
        if (confirmAttempts >= maxConfirmAttempts) {
          console.log('⏰ Max confirmation attempts reached, restarting search...');
          setError('⏰ Connection failed after multiple attempts, searching for another match...');
          
          // Restart search process
          setTimeout(() => {
            if (isActiveRef.current) {
              setIsSearching(true);
              startSearchProcess(userId);
            }
          }, 2000);
          return;
        }

        if (error.message.includes('timeout')) {
          console.log('⏰ Bilateral confirmation timeout, restarting search...');
          setError('⏰ Connection timeout, searching for another match...');
          
          // Restart search process
          setTimeout(() => {
            if (isActiveRef.current) {
              setIsSearching(true);
              startSearchProcess(userId);
            }
          }, 2000);
        } else {
          setError(`🔄 Connection failed, retrying... (${confirmAttempts}/${maxConfirmAttempts})`);
          setTimeout(() => {
            if (isActiveRef.current) {
              confirmMatch();
            }
          }, 1000);
        }
      }
    };

    // Start confirmation with timeout
    bilateralTimeoutRef.current = setTimeout(() => {
      console.log('⏰ Bilateral confirmation timeout');
      setError('⏰ Connection timeout, searching for another match...');
      if (isActiveRef.current) {
        setIsSearching(true);
        startSearchProcess(userId);
      }
    }, 30000); // 30 second total timeout

    confirmMatch();
  }, [startSearchProcess, stopWaitTimer, stopAllIntervals]);

  // Leave queue safely with proper cleanup
  const leaveQueue = useCallback(async () => {
    try {
      console.log('🚪 Leaving waiting queue...');
      isActiveRef.current = false;
      
      if (currentUserIdRef.current) {
        const { data, error } = await supabase.rpc('leave_waiting_queue_v2', {
          p_user_id: currentUserIdRef.current
        });

        if (error) {
          console.warn('⚠️ Error leaving queue:', error.message);
        } else {
          console.log('✅ Successfully left queue');
        }
      }

      // Reset all state
      setIsInQueue(false);
      setIsSearching(false);
      setMatchResult(null);
      setError(null);
      setSearchAttempts(0);
      setQueueStats(null);
      setQueuePosition(null);
      setEstimatedWait(null);
      
      // Stop all intervals and timers
      stopAllIntervals();
      stopWaitTimer();

      currentUserIdRef.current = null;
      currentSessionIdRef.current = null;

    } catch (error) {
      console.error('❌ Error leaving queue:', error);
    }
  }, [stopAllIntervals, stopWaitTimer]);

  // Auto-reconnect on disconnect detection
  const handleDisconnectReconnect = useCallback(async () => {
    if (!isActiveRef.current) return;
    
    console.log('🔄 Disconnect detected, attempting auto-reconnect...');
    setError('🔄 Connection lost, reconnecting...');
    
    // Brief pause then rejoin
    setTimeout(() => {
      if (currentUserIdRef.current) {
        console.log('🔄 Auto-reconnecting to queue...');
        joinQueue(currentUserIdRef.current);
      }
    }, 3000);
  }, [joinQueue]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      console.log('🧹 Cleaning up matching queue hook');
      isActiveRef.current = false;
      leaveQueue();
    };
  }, [leaveQueue]);

  // Handle page visibility changes for better resource management
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (document.hidden) {
        console.log('👁️ Page hidden - reducing search frequency');
        // Could reduce heartbeat frequency here if needed
      } else {
        console.log('👁️ Page visible - resuming normal activity');
        if (currentUserIdRef.current && isActiveRef.current) {
          sendHeartbeat(currentUserIdRef.current);
          updateQueueStats();
        }
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);
    return () => document.removeEventListener('visibilitychange', handleVisibilityChange);
  }, [sendHeartbeat, updateQueueStats]);

  // Handle online/offline events
  useEffect(() => {
    const handleOnline = () => {
      console.log('🌐 Back online - reconnecting to queue...');
      handleDisconnectReconnect();
    };

    const handleOffline = () => {
      console.log('📴 Gone offline - will reconnect when back online');
      setError('📴 Connection lost - will reconnect when back online');
    };

    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);

    return () => {
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
    };
  }, [handleDisconnectReconnect]);

  return {
    isInQueue,
    isSearching,
    waitTime,
    queueStats,
    matchResult,
    error,
    searchAttempts,
    connectionQuality,
    queuePosition,
    estimatedWait,
    joinQueue,
    leaveQueue,
    updateQueueStats,
    handleDisconnectReconnect,
  };
};