import { useEffect, useRef, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import { RealtimeChannel } from '@supabase/supabase-js';

interface UseSupabaseRealtimeProps {
  userId?: string;
  chatId?: string;
  onMessageReceived?: (message: any) => void;
  onUserDisconnected?: () => void;
  onPresenceUpdate?: (presence: any) => void;
  onChatUpdate?: (chat: any) => void;
  onBilateralMatchFound?: (matchData: any) => void;
}

export const useSupabaseRealtime = ({
  userId,
  chatId,
  onMessageReceived,
  onUserDisconnected,
  onPresenceUpdate,
  onChatUpdate,
  onBilateralMatchFound
}: UseSupabaseRealtimeProps) => {
  const channelRef = useRef<RealtimeChannel | null>(null);
  const presenceChannelRef = useRef<RealtimeChannel | null>(null);
  const matchingChannelRef = useRef<RealtimeChannel | null>(null);
  const heartbeatRef = useRef<NodeJS.Timeout | null>(null);
  const cleanupRef = useRef<NodeJS.Timeout | null>(null);
  const isActiveRef = useRef<boolean>(true);
  const reconnectAttemptsRef = useRef<number>(0);
  const maxReconnectAttempts = 10;
  const baseReconnectDelay = 1000; // 1 second base delay

  // Enhanced presence update with heartbeat
  const updatePresence = useCallback(async (status: 'online' | 'offline' | 'away' = 'online') => {
    if (!userId || !isActiveRef.current) return;

    try {
      if (Math.random() < 0.1) { // Log only 10% to reduce spam
        console.log('💓 Updating presence:', status);
      }
      const { error } = await supabase.rpc('send_heartbeat_v2', { 
        p_user_id: userId,
        p_connection_quality: 100
      });

      if (error) {
        console.warn('💔 Failed to update presence:', error.message);
      } else {
        if (Math.random() < 0.05) { // Log only 5% of successes
          console.log('✅ Presence updated successfully');
        }
        reconnectAttemptsRef.current = 0; // Reset on success
      }
    } catch (error) {
      console.warn('💔 Error updating presence:', error);
      
      // Auto-reconnect logic with exponential backoff
      if (reconnectAttemptsRef.current < maxReconnectAttempts) {
        reconnectAttemptsRef.current++;
        const delay = Math.min(baseReconnectDelay * Math.pow(2, reconnectAttemptsRef.current - 1), 30000);
        console.log(`🔄 Attempting reconnect ${reconnectAttemptsRef.current}/${maxReconnectAttempts} in ${delay}ms`);
        setTimeout(() => updatePresence(status), delay);
      }
    }
  }, [userId]);

  // Setup bilateral matching channel for real-time match notifications
  useEffect(() => {
    if (!userId) return;
    
    console.log('🔗 Setting up realtime matching channel for user:', userId);
    
    const setupMatchingChannel = async () => {
      try {
        const channelName = `waiting_users:${userId}`;
        matchingChannelRef.current = supabase.channel(channelName, {
          config: {
            broadcast: { self: true },
            presence: { key: userId },
            postgres_changes: { enabled: true }
          }
        });

        matchingChannelRef.current
          // Listen for match broadcasts
          .on('broadcast', { event: 'match_found' }, (payload) => {
            if (!isActiveRef.current) return;
            console.log('🎉 Match broadcast received:', payload);
            onBilateralMatchFound?.(payload.payload);
          })
          .on('broadcast', { event: 'match_confirmed' }, (payload) => {
            if (!isActiveRef.current) return;
            console.log('✅ Confirmation broadcast received:', payload);
            onBilateralMatchFound?.(payload.payload);
          })
          // Listen for database changes on waiting_users table
          .on(
            'postgres_changes',
            {
              event: '*',
              schema: 'public',
              table: 'waiting_users'
            },
            (payload) => {
              if (!isActiveRef.current) return;
              try {
                console.log('👥 Waiting users table changed:', payload.eventType);
                // Trigger match search when new users join
                if (payload.eventType === 'INSERT' && payload.new?.id !== userId) {
                  console.log('👋 New user joined queue, checking for matches...');
                  // Could trigger immediate match check here
                }
              } catch (error) {
                console.warn('⚠️ Error handling waiting_users change:', error);
              }
            }
          )
          // Listen for match_attempts changes
          .on(
            'postgres_changes',
            {
              event: '*',
              schema: 'public',
              table: 'match_attempts',
              filter: `user1_id=eq.${userId},user2_id=eq.${userId}`
            },
            (payload) => {
              if (!isActiveRef.current) return;
              try {
                console.log('🤝 Match attempt updated:', payload.eventType, payload.new?.status);
                if (payload.new?.status === 'confirmed') {
                  console.log('✅ Match confirmed via database change');
                  onBilateralMatchFound?.(payload.new);
                }
              } catch (error) {
                console.warn('⚠️ Error handling match_attempts change:', error);
              }
            }
          )
          .subscribe(async (status) => {
            if (status === 'SUBSCRIBED') {
              console.log('✅ Realtime matching channel subscribed');
            } else if (status === 'CHANNEL_ERROR') {
              console.error('❌ Matching channel error, reconnecting in 5s...');
              setTimeout(setupMatchingChannel, 5000);
            } else if (status === 'CLOSED') {
              console.warn('🔌 Matching channel closed, reconnecting...');
              setTimeout(setupMatchingChannel, 2000);
            }
          });

      } catch (error) {
        console.error('❌ Error setting up matching channel:', error);
        setTimeout(setupMatchingChannel, 5000);
      }
    };

    setupMatchingChannel();

    return () => {
      if (matchingChannelRef.current) {
        console.log('🔌 Unsubscribing from matching channel');
        matchingChannelRef.current.unsubscribe();
        matchingChannelRef.current = null;
      }
    };
  }, [userId, onBilateralMatchFound]);

  // Setup comprehensive presence tracking
  useEffect(() => {
    if (!userId) {
      isActiveRef.current = false;
      return;
    }
    
    isActiveRef.current = true;
    console.log('👥 Setting up presence tracking for user:', userId);

    const setupPresence = async () => {
      try {
        // Create presence channel with enhanced config
        const presenceRoom = `presence:${userId}`;
        presenceChannelRef.current = supabase.channel(presenceRoom, {
          config: {
            presence: {
              key: userId,
              timeout: 60000, // 60 seconds timeout (increased from 30s)
            },
            broadcast: { self: false },
          },
        });

        // Handle presence events
        presenceChannelRef.current
          .on('presence', { event: 'sync' }, () => {
            if (!isActiveRef.current) return;
            try {
              if (Math.random() < 0.1) { // Log only 10% to reduce spam
                console.log('👥 Presence sync event');
              }
              const state = presenceChannelRef.current?.presenceState();
              onPresenceUpdate?.(state);
            } catch (error) {
              console.warn('⚠️ Error handling presence sync:', error);
            }
          })
          .on('presence', { event: 'join' }, ({ key, newPresences }) => {
            if (!isActiveRef.current) return;
            try {
              if (key !== userId) {
                console.log('👋 User joined presence:', key);
              }
              onPresenceUpdate?.({ type: 'join', key, presences: newPresences });
            } catch (error) {
              console.warn('⚠️ Error handling presence join:', error);
            }
          })
          .on('presence', { event: 'leave' }, ({ key, leftPresences }) => {
            if (!isActiveRef.current) return;
            try {
              if (key !== userId) {
                console.log('👋 User left presence:', key);
                console.log('🚪 Partner may have disconnected, confirming...');
                
                // Confirm disconnection with RPC before triggering disconnect
                setTimeout(async () => {
                  if (!isActiveRef.current) return;
                  try {
                    const { data, error } = await supabase.rpc('check_user_status', {
                      p_user_id: key
                    });
                    
                    if (error || !data?.is_active) {
                      console.log('✅ Confirmed: Partner disconnected');
                      onUserDisconnected?.();
                    } else {
                      console.log('ℹ️ False alarm: Partner still active');
                    }
                  } catch (confirmError) {
                    console.warn('⚠️ Could not confirm disconnect, assuming disconnected:', confirmError);
                    onUserDisconnected?.();
                  }
                }, 2000); // 2 second grace period
              }
              onPresenceUpdate?.({ type: 'leave', key, presences: leftPresences });
            } catch (error) {
              console.warn('⚠️ Error handling presence leave:', error);
            }
          })
          .subscribe(async (status) => {
            if (!isActiveRef.current) return;
            if (status === 'SUBSCRIBED') {
              console.log('✅ Presence channel subscribed');
              try {
                // Track this user as online
                await presenceChannelRef.current?.track({
                  user_id: userId,
                  online_at: new Date().toISOString(),
                  status: 'online',
                  last_heartbeat: new Date().toISOString(),
                  connection_quality: 100
                });
                
                await updatePresence('online');
              } catch (error) {
                console.warn('⚠️ Error tracking presence:', error);
              }
            } else if (status === 'CHANNEL_ERROR') {
              console.error('❌ Presence channel error, reconnecting...');
              setTimeout(setupPresence, 5000);
            } else if (status === 'CLOSED') {
              console.warn('🔌 Presence channel closed, reconnecting...');
              setTimeout(setupPresence, 2000);
            }
          });

        // Setup enhanced heartbeat every 5 seconds (reduced from 10s)
        if (heartbeatRef.current) {
          clearInterval(heartbeatRef.current);
        }
        heartbeatRef.current = setInterval(async () => {
          if (!isActiveRef.current) return;
          try {
            if (Math.random() < 0.1) { // Log only 10% to reduce spam
              console.log('💓 Sending presence heartbeat');
            }
            await updatePresence('online');
            
            // Update presence tracking
            if (presenceChannelRef.current) {
              await presenceChannelRef.current.track({
                user_id: userId,
                online_at: new Date().toISOString(),
                status: 'online',
                last_heartbeat: new Date().toISOString(),
                connection_quality: 100
              });
            }
          } catch (error) {
            console.warn('💔 Heartbeat failed:', error);
          }
        }, 3000); // Every 3 seconds for keep-alive (reduced from 5s)

        // Setup cleanup interval - reduced frequency
        if (cleanupRef.current) {
          clearInterval(cleanupRef.current);
        }
        cleanupRef.current = setInterval(async () => {
          if (!isActiveRef.current) return;
          try {
            if (Math.random() < 0.2) { // Log only 20% to reduce spam
              console.log('🧹 Running periodic cleanup');
            }
            await supabase.rpc('cleanup_inactive_sessions_v2');
          } catch (error) {
            console.warn('🧹 Cleanup failed:', error);
          }
        }, 60000); // Every 60 seconds (reduced from 90s)

      } catch (error) {
        console.error('❌ Error setting up presence:', error);
        setTimeout(setupPresence, 5000);
      }
    };

    setupPresence();

    return () => {
      console.log('🧹 Cleaning up presence tracking');
      isActiveRef.current = false;
      if (heartbeatRef.current) {
        clearInterval(heartbeatRef.current);
        heartbeatRef.current = null;
      }
      if (cleanupRef.current) {
        clearInterval(cleanupRef.current);
        cleanupRef.current = null;
      }
      if (presenceChannelRef.current) {
        presenceChannelRef.current.unsubscribe();
        presenceChannelRef.current = null;
      }
    };
  }, [userId, updatePresence, onPresenceUpdate, onUserDisconnected]);

  // Setup chat realtime subscriptions with comprehensive error handling
  useEffect(() => {
    if (!chatId || !isActiveRef.current) return;
    
    console.log('💬 Setting up chat realtime for chat:', chatId);

    const setupChatRealtime = async () => {
      try {
        // Create chat channel
        channelRef.current = supabase.channel(`chat:${chatId}`);

        // Listen for new messages with error handling
        channelRef.current
          .on(
            'postgres_changes',
            {
              event: 'INSERT',
              schema: 'public',
              table: 'chat_messages',
              filter: `chat_id=eq.${chatId}`,
            },
            (payload) => {
              if (!isActiveRef.current) return;
              try {
                console.log('📨 New message received via realtime');
                const message = payload.new as any;
                // Only process messages from other users
                if (message.sender_id !== userId) {
                  onMessageReceived?.(message);
                }
              } catch (error) {
                console.warn('⚠️ Error handling new message:', error);
              }
            }
          )
          .on(
            'postgres_changes',
            {
              event: 'UPDATE',
              schema: 'public',
              table: 'chat_sessions',
              filter: `chat_id=eq.${chatId}`,
            },
            (payload) => {
              if (!isActiveRef.current) return;
              try {
                console.log('💬 Chat session updated:', payload.new?.status);
                const updatedChat = payload.new as any;
                onChatUpdate?.(updatedChat);
                
                if (updatedChat.status === 'ended') {
                  console.log('🚪 Chat ended, triggering disconnect');
                  onUserDisconnected?.();
                }
              } catch (error) {
                console.warn('⚠️ Error handling chat update:', error);
              }
            }
          )
          .on(
            'postgres_changes',
            {
              event: 'UPDATE',
              schema: 'public',
              table: 'active_users',
            },
            (payload) => {
              if (!isActiveRef.current) return;
              try {
                console.log('👤 Active user updated:', payload.new?.status);
                const updatedUser = payload.new as any;
                
                // Check if partner disconnected
                if (updatedUser.status === 'offline' && updatedUser.id !== userId) {
                  console.log('🚪 Partner went offline, triggering disconnect');
                  onUserDisconnected?.();
                }
              } catch (error) {
                console.warn('⚠️ Error handling user update:', error);
              }
            }
          )
          .subscribe((status) => {
            if (status === 'CHANNEL_ERROR') {
              console.error('❌ Chat channel error, attempting to reconnect...');
              setTimeout(() => {
                if (isActiveRef.current) {
                  setupChatRealtime();
                }
              }, 5000);
            } else if (status === 'SUBSCRIBED') {
              console.log('✅ Chat channel subscribed');
            } else if (status === 'CLOSED') {
              console.warn('🔌 Chat channel closed, reconnecting...');
              setTimeout(() => {
                if (isActiveRef.current) {
                  setupChatRealtime();
                }
              }, 2000);
            }
          });

      } catch (error) {
        console.error('❌ Error setting up chat realtime:', error);
        // Retry setup after delay
        setTimeout(() => {
          if (isActiveRef.current) {
            setupChatRealtime();
          }
        }, 5000);
      }
    };

    setupChatRealtime();

    return () => {
      console.log('🧹 Cleaning up chat realtime');
      if (channelRef.current) {
        channelRef.current.unsubscribe();
        channelRef.current = null;
      }
    };
  }, [chatId, onMessageReceived, onUserDisconnected, onChatUpdate, userId]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      console.log('🧹 Final cleanup on unmount');
      isActiveRef.current = false;
      updatePresence('offline');
    };
  }, [updatePresence]);

  // Broadcast message to chat
  const broadcastMessage = useCallback(async (message: any) => {
    if (!channelRef.current || !isActiveRef.current) return;

    try {
      console.log('📤 Broadcasting message:', message);
      await channelRef.current.send({
        type: 'broadcast',
        event: 'new_message',
        payload: message
      });
    } catch (error) {
      console.warn('⚠️ Failed to broadcast message:', error);
    }
  }, []);

  // Broadcast bilateral match found
  const broadcastMatchFound = useCallback(async (matchData: any) => {
    if (!matchingChannelRef.current || !isActiveRef.current) return;

    try {
      console.log('📡 Broadcasting match found to partner');
      await matchingChannelRef.current.send({
        type: 'broadcast',
        event: 'match_found',
        payload: matchData,
        config: { self: false } // Ensure partner receives but not self
      });
    } catch (error) {
      console.warn('⚠️ Failed to broadcast match:', error);
    }
  }, []);

  // Force refresh subscriptions on connection issues
  const refreshSubscriptions = useCallback(async () => {
    if (!isActiveRef.current) return [];
    
    try {
      console.log('🔄 Refreshing subscriptions...');
      
      // Unsubscribe and resubscribe to all channels
      if (presenceChannelRef.current) {
        await presenceChannelRef.current.unsubscribe();
        presenceChannelRef.current = null;
      }
      
      if (channelRef.current) {
        await channelRef.current.unsubscribe();
        channelRef.current = null;
      }
      
      if (matchingChannelRef.current) {
        await matchingChannelRef.current.unsubscribe();
        matchingChannelRef.current = null;
      }
      
      // Force re-setup after a short delay
      setTimeout(() => {
        if (isActiveRef.current && userId) {
          // Presence will be re-setup by useEffect
          console.log('✅ All subscriptions refreshed');
        }
      }, 2000);
      
    } catch (error) {
      console.warn('⚠️ Failed to refresh subscriptions:', error);
    }
  }, [userId]);

  return {
    updatePresence,
    broadcastMessage,
    broadcastMatchFound,
    refreshSubscriptions,
  };
};