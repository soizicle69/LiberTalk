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

  const requestLocation = async (): Promise<GeolocationData | null> => {
    setLoading(true);
    setError(null);

    try {
      // Check if geolocation is supported
      if (!('geolocation' in navigator)) {
        throw new Error('Geolocation is not supported by this browser');
      }

      // Request high-accuracy location
      const position = await new Promise<GeolocationPosition>((resolve, reject) => {
        navigator.geolocation.getCurrentPosition(
          resolve,
          reject,
          {
            enableHighAccuracy: true,
            timeout: 15000,
            maximumAge: 300000, // 5 minutes cache
          }
        );
      });

      const { latitude, longitude, accuracy } = position.coords;
      const continent = getContinent(latitude, longitude);

      // Try to get more detailed location info from reverse geocoding
      let country = 'Unknown';
      let region = 'Unknown';
      let city = 'Unknown';

      try {
        // Use a free reverse geocoding service
        const response = await fetch(
          `https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=${latitude}&longitude=${longitude}&localityLanguage=en`
        );
        
        if (response.ok) {
          const data = await response.json();
          country = data.countryName || 'Unknown';
          region = data.principalSubdivision || 'Unknown';
          city = data.city || data.locality || 'Unknown';
        }
      } catch (geocodeError) {
        console.warn('Reverse geocoding failed:', geocodeError);
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
      setPermissionStatus('granted');
      return locationData;

    } catch (geoError: any) {
      console.error('Geolocation error:', geoError);
      
      let errorMessage = 'Unable to get your location';
      
      if (geoError.code === 1) {
        errorMessage = 'Location access denied. Please enable location permissions.';
        setPermissionStatus('denied');
        setPermissionStatus('denied');
      } else if (geoError.code === 2) {
        errorMessage = 'Location unavailable. Please check your GPS/network.';
      } else if (geoError.code === 3) {
        errorMessage = 'Location request timed out. Please try again.';
      }

      setError(errorMessage);
      
      // Fallback to IP-based location
      try {
        const response = await fetch('https://ipapi.co/json/');
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
          
          setLocation(fallbackLocation);
          setIsIPBased(true);
          setError(geoError.code === 1 ? 'Using IP-based location (less precise)' : 'Using approximate location based on IP address');
          return fallbackLocation;
        }
      } catch (ipError) {
        console.error('IP geolocation also failed:', ipError);
      }

      return null;
    } finally {
      setLoading(false);
    }
  };

  // Check permission status on mount
  useEffect(() => {
    if ('permissions' in navigator) {
      navigator.permissions.query({ name: 'geolocation' }).then((result) => {
        setPermissionStatus(result.state as 'prompt' | 'granted' | 'denied');
      });
    }
  }, []);
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
    permissionStatus,
    requestLocation 
  };
};