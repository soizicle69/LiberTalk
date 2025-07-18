import { useState, useEffect } from 'react';

interface GeolocationData {
  latitude: number;
  longitude: number;
  continent: string;
  country: string;
  region: string;
  city: string;
  accuracy?: number;
}

export const useGeolocation = () => {
  const [location, setLocation] = useState<GeolocationData | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [permissionStatus, setPermissionStatus] = useState<'prompt' | 'granted' | 'denied'>('prompt');
  const [isIPBased, setIsIPBased] = useState(false);

  // Map coordinates to continent (more precise)
  const getContinent = (lat: number, lng: number): string => {
    // Europe boundaries (more precise)
    if (lat >= 35 && lat <= 71 && lng >= -25 && lng <= 45) {
      return 'Europe';
    }
    // North America
    if (lat >= 15 && lat <= 72 && lng >= -168 && lng <= -52) {
      return 'North America';
    }
    // Asia
    if (lat >= -10 && lat <= 77 && lng >= 25 && lng <= 180) {
      return 'Asia';
    }
    // Africa
    if (lat >= -35 && lat <= 37 && lng >= -20 && lng <= 55) {
      return 'Africa';
    }
    // South America
    if (lat >= -56 && lat <= 13 && lng >= -82 && lng <= -35) {
      return 'South America';
    }
    // Australia/Oceania
    if (lat >= -50 && lat <= -10 && lng >= 110 && lng <= 180) {
      return 'Oceania';
    }
    return 'Unknown';
  };

  // Non-blocking geolocation with strict timeout
  const requestLocationNonBlocking = async (timeoutMs: number = 2000): Promise<GeolocationData | null> => {
    setLoading(true);
    setError(null);

    try {
      console.log(`📍 Starting FORCED non-blocking geolocation (${timeoutMs/1000}s max, will proceed regardless)...`);
      
      // Check browser permission status first
      if ('permissions' in navigator) {
        try {
          const permission = await navigator.permissions.query({ name: 'geolocation' });
          console.log('📍 Geolocation permission status:', permission.state);
          
          if (permission.state === 'denied') {
            console.log('📍 Geolocation denied by user, skipping to IP fallback immediately');
            setPermissionStatus('denied');
            throw new Error('Geolocation permission denied');
          }
        } catch (permError) {
          console.warn('📍 Permission check failed, continuing anyway:', permError);
        }
      }
      
      // Check if geolocation is supported
      if (!('geolocation' in navigator)) {
        console.log('📍 Geolocation not supported, skipping to IP fallback');
        throw new Error('Geolocation not supported');
      }

      // Create geolocation promise with strict timeout
      const geolocPromise = new Promise<GeolocationPosition>((resolve, reject) => {
        navigator.geolocation.getCurrentPosition(
          resolve,
          reject,
          {
            enableHighAccuracy: false, // Faster response
            timeout: timeoutMs - 1000, // Internal timeout slightly less than external
            maximumAge: 300000, // 5 minutes cache
          }
        );
      });

      // Create timeout promise
      const timeoutPromise = new Promise<never>((_, reject) => {
        setTimeout(() => {
          console.log(`📍 FORCED timeout after ${timeoutMs/1000}s - proceeding with IP fallback`);
          reject(new Error('Geolocation timeout'));
        }, timeoutMs);
      });

      // Race between geolocation and timeout
      const position = await Promise.race([geolocPromise, timeoutPromise]);

      const { latitude, longitude, accuracy } = position.coords;
      const continent = getContinent(latitude, longitude);

      console.log('📍 GPS location obtained:', { latitude, longitude, continent, accuracy });

      // Try reverse geocoding with timeout
      let country = 'Unknown';
      let region = 'Unknown';
      let city = 'Unknown';

      try {
        const geocodePromise = fetch(
          `https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=${latitude}&longitude=${longitude}&localityLanguage=en`
        );
        
        const geocodeTimeout = new Promise<never>((_, reject) => {
          setTimeout(() => reject(new Error('Geocoding timeout')), 2000);
        });

        const response = await Promise.race([geocodePromise, geocodeTimeout]);
        
        if (response.ok) {
          const data = await response.json();
          country = data.countryName || 'Unknown';
          region = data.principalSubdivision || 'Unknown';
          city = data.city || data.locality || 'Unknown';
          console.log('📍 Reverse geocoding successful:', { country, region, city });
        }
      } catch (geocodeError) {
        console.warn('📍 Reverse geocoding failed, using coordinates only:', geocodeError);
      }

      const locationData: GeolocationData = {
        latitude,
        longitude,
        continent,
        country,
        region,
        city,
        accuracy,
      };

      setLocation(locationData);
      setPermissionStatus('granted');
      setIsIPBased(false);
      console.log('✅ GPS location set successfully');
      return locationData;

    } catch (geoError: any) {
      console.log('📍 GPS failed, FORCING IP fallback (will proceed regardless):', geoError.message);
      
      // Set permission status based on error
      if (geoError.code === 1) {
        setPermissionStatus('denied');
        setError('Location access denied - using IP location');
      } else {
        setError('GPS unavailable - using IP location');
      }

      // IP-based fallback with timeout
      try {
        console.log('🌐 FORCED IP-based geolocation (1s timeout)...');
        
        const ipPromise = fetch('https://ipapi.co/json/');
        const ipTimeout = new Promise<never>((_, reject) => {
          setTimeout(() => reject(new Error('IP geolocation timeout')), 1000);
        });

        const response = await Promise.race([ipPromise, ipTimeout]);
        const data = await response.json();
        
        if (!data.error && data.latitude && data.longitude) {
          const fallbackLocation: GeolocationData = {
            latitude: data.latitude,
            longitude: data.longitude,
            continent: data.continent_code === 'EU' ? 'Europe' : 
                      data.continent_code === 'NA' ? 'North America' :
                      data.continent_code === 'AS' ? 'Asia' :
                      data.continent_code === 'AF' ? 'Africa' :
                      data.continent_code === 'SA' ? 'South America' :
                      data.continent_code === 'OC' ? 'Oceania' : 'Unknown',
            country: data.country_name || 'Unknown',
            region: data.region || 'Unknown',
            city: data.city || 'Unknown',
          };
          
          console.log('✅ IP location obtained:', fallbackLocation);
          setLocation(fallbackLocation);
          setIsIPBased(true);
          setError('Using IP-based location (less precise)');
          return fallbackLocation;
        } else {
          console.log('📍 IP geolocation invalid, FORCING null (will proceed anyway):', data);
        }
      } catch (ipError) {
        console.warn('📍 IP geolocation failed, FORCING null (will proceed anyway):', ipError);
      }

      // FORCED fallback - always return null and proceed
      console.log('📍 FORCED PROGRESSION: All location methods failed, returning null and proceeding with global matching');
      setError('Location unavailable - using global matching');
      return null;

    } finally {
      setLoading(false);
      console.log('📍 FORCED COMPLETION: Geolocation process completed, app will proceed');
    }
  };

  // Legacy method for compatibility
  const requestLocation = requestLocationNonBlocking;

  // Check permission status on mount
  useEffect(() => {
    if ('permissions' in navigator) {
      navigator.permissions.query({ name: 'geolocation' }).then((result) => {
        setPermissionStatus(result.state as 'prompt' | 'granted' | 'denied');
      });
    }
  }, []);

  return { 
    location, 
    loading, 
    error, 
    permissionStatus,
    isIPBased,
    requestLocation,
    requestLocationNonBlocking
  };
};