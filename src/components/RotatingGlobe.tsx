import React, { useEffect, useRef } from 'react';

interface GlobeProps {
  onlineUsers?: number;
}

export const RotatingGlobe: React.FC<GlobeProps> = ({ onlineUsers = 0 }) => {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const animationRef = useRef<number>();
  const pointsRef = useRef<Array<{
    phi: number;
    theta: number;
    pulse: number;
    type: 'normal' | 'europe' | 'connection';
  }>>([]);
  const connectionsRef = useRef<Array<{
    from: number;
    to: number;
    progress: number;
    speed: number;
  }>>([]);
  const startTimeRef = useRef<number>(Date.now());

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    // Responsive canvas size
    const updateCanvasSize = () => {
      const size = Math.min(window.innerWidth * 0.8, 500);
      canvas.width = size;
      canvas.height = size;
    };

    updateCanvasSize();
    window.addEventListener('resize', updateCanvasSize);

    const centerX = canvas.width / 2;
    const centerY = canvas.height / 2;
    const radius = Math.min(canvas.width, canvas.height) * 0.35;

    // Initialize points once with fixed positions
    if (pointsRef.current.length === 0) {
      // Regular connection points
      for (let i = 0; i < 40; i++) {
        pointsRef.current.push({
          phi: Math.random() * Math.PI * 2,
          theta: Math.random() * Math.PI,
          pulse: Math.random() * Math.PI * 2,
          type: 'normal'
        });
      }

      // European points (concentrated in Europe region)
      for (let i = 0; i < 15; i++) {
        pointsRef.current.push({
          phi: (Math.PI * 0.8) + (Math.random() - 0.5) * 0.8, // Europe longitude
          theta: (Math.PI * 0.35) + (Math.random() - 0.5) * 0.3, // Europe latitude
          pulse: Math.random() * Math.PI * 2,
          type: 'europe'
        });
      }

      // Major connection hubs
      const majorCities = [
        { phi: Math.PI * 0.85, theta: Math.PI * 0.35 }, // London
        { phi: Math.PI * 0.9, theta: Math.PI * 0.38 },  // Paris
        { phi: Math.PI * 0.95, theta: Math.PI * 0.36 }, // Berlin
        { phi: Math.PI * 0.7, theta: Math.PI * 0.4 },   // New York
        { phi: Math.PI * 1.6, theta: Math.PI * 0.45 },  // Tokyo
        { phi: Math.PI * 1.4, theta: Math.PI * 0.5 },   // Sydney
      ];

      majorCities.forEach(city => {
        pointsRef.current.push({
          ...city,
          pulse: Math.random() * Math.PI * 2,
          type: 'connection'
        });
      });

      // Initialize connections between points
      for (let i = 0; i < 12; i++) {
        connectionsRef.current.push({
          from: Math.floor(Math.random() * pointsRef.current.length),
          to: Math.floor(Math.random() * pointsRef.current.length),
          progress: Math.random(),
          speed: 0.005 + Math.random() * 0.01
        });
      }

      startTimeRef.current = Date.now();
    }

    function animate() {
      if (!ctx || !canvas) return;

      ctx.clearRect(0, 0, canvas.width, canvas.height);
      
      const currentTime = Date.now();
      const elapsedTime = currentTime - startTimeRef.current;
      
      // Global rotation: complete rotation in 60 seconds
      const globalRotation = (elapsedTime / 60000) * Math.PI * 2;

      // Draw globe outline with glow effect
      ctx.shadowColor = '#00D4FF';
      ctx.shadowBlur = 15;
      ctx.strokeStyle = 'rgba(0, 212, 255, 0.4)';
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(centerX, centerY, radius, 0, Math.PI * 2);
      ctx.stroke();
      ctx.shadowBlur = 0;

      // Draw latitude lines
      ctx.strokeStyle = 'rgba(0, 212, 255, 0.15)';
      ctx.lineWidth = 1;
      for (let i = 1; i < 8; i++) {
        const y = centerY - radius + (radius * 2 * i) / 8;
        const width = Math.sqrt(radius * radius - Math.pow(y - centerY, 2)) * 2;
        
        if (width > 0) {
          ctx.beginPath();
          ctx.ellipse(centerX, y, width / 2, width / 12, 0, 0, Math.PI * 2);
          ctx.stroke();
        }
      }

      // Draw longitude lines
      for (let i = 0; i < 12; i++) {
        const angle = (Math.PI * 2 * i) / 12;
        ctx.beginPath();
        ctx.ellipse(centerX, centerY, Math.abs(radius * Math.cos(angle)), radius, angle, 0, Math.PI * 2);
        ctx.stroke();
      }

      // Calculate 3D positions for all points
      const points3D = pointsRef.current.map((point, index) => {
        const rotatedPhi = point.phi + globalRotation;
        const x = centerX + radius * Math.sin(point.theta) * Math.cos(rotatedPhi);
        const y = centerY + radius * Math.cos(point.theta);
        const z = radius * Math.sin(point.theta) * Math.sin(rotatedPhi);
        
        return { x, y, z, index, ...point };
      });

      // Draw connections between points
      connectionsRef.current.forEach(connection => {
        const fromPoint = points3D[connection.from];
        const toPoint = points3D[connection.to];
        
        if (fromPoint && toPoint && fromPoint.z > -radius * 0.5 && toPoint.z > -radius * 0.5) {
          // Draw connection line
          const gradient = ctx.createLinearGradient(fromPoint.x, fromPoint.y, toPoint.x, toPoint.y);
          gradient.addColorStop(0, 'rgba(0, 212, 255, 0.1)');
          gradient.addColorStop(0.5, 'rgba(0, 212, 255, 0.3)');
          gradient.addColorStop(1, 'rgba(0, 212, 255, 0.1)');
          
          ctx.strokeStyle = gradient;
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.moveTo(fromPoint.x, fromPoint.y);
          ctx.lineTo(toPoint.x, toPoint.y);
          ctx.stroke();

          // Draw data packet moving along connection
          const packetX = fromPoint.x + (toPoint.x - fromPoint.x) * connection.progress;
          const packetY = fromPoint.y + (toPoint.y - fromPoint.y) * connection.progress;
          
          ctx.fillStyle = 'rgba(0, 255, 150, 0.8)';
          ctx.beginPath();
          ctx.arc(packetX, packetY, 2, 0, Math.PI * 2);
          ctx.fill();

          // Update connection progress
          connection.progress += connection.speed;
          if (connection.progress > 1) {
            connection.progress = 0;
            // Randomly reassign connection endpoints
            connection.from = Math.floor(Math.random() * pointsRef.current.length);
            connection.to = Math.floor(Math.random() * pointsRef.current.length);
          }
        }
      });

      // Draw points with different styles based on type
      points3D.forEach((point) => {
        // Only draw visible points (front hemisphere)
        if (point.z > -radius * 0.3) {
          const pulse = Math.sin(currentTime * 0.003 + point.pulse) * 0.3 + 0.7;
          const depthFactor = (point.z + radius) / (2 * radius);
          
          let size, color, glowIntensity;
          
          switch (point.type) {
            case 'europe':
              size = 2 + pulse * 2;
              color = `rgba(255, 193, 7, ${0.6 + pulse * 0.4})`;
              glowIntensity = 12;
              break;
            case 'connection':
              size = 3 + pulse * 2.5;
              color = `rgba(255, 64, 129, ${0.7 + pulse * 0.3})`;
              glowIntensity = 15;
              break;
            default:
              size = 1.5 + pulse * 1.5;
              color = `rgba(0, 212, 255, ${0.4 + pulse * 0.4})`;
              glowIntensity = 8;
          }

          const finalAlpha = depthFactor * 0.8 + 0.2;
          
          // Draw point with glow
          if (depthFactor > 0.5) {
            ctx.shadowColor = color.includes('255, 193') ? '#FFC107' : 
                             color.includes('255, 64') ? '#FF4081' : '#00D4FF';
            ctx.shadowBlur = glowIntensity;
          }
          
          ctx.fillStyle = color;
          ctx.beginPath();
          ctx.arc(point.x, point.y, size * finalAlpha, 0, Math.PI * 2);
          ctx.fill();
          ctx.shadowBlur = 0;
        }
      });

      // Draw orbital rings
      for (let i = 0; i < 3; i++) {
        const ringRadius = radius + 20 + i * 15;
        const opacity = 0.1 - i * 0.02;
        const pulsePhase = (currentTime * 0.001) + i * Math.PI * 0.6;
        const pulseFactor = Math.sin(pulsePhase) * 0.3 + 0.7;
        
        ctx.strokeStyle = `rgba(0, 212, 255, ${opacity * pulseFactor})`;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(centerX, centerY, ringRadius, 0, Math.PI * 2);
        ctx.stroke();
      }

      animationRef.current = requestAnimationFrame(animate);
    }

    animate();

    return () => {
      window.removeEventListener('resize', updateCanvasSize);
      if (animationRef.current) {
        cancelAnimationFrame(animationRef.current);
      }
    };
  }, []);

  return (
    <div className="fixed inset-0 pointer-events-none overflow-hidden">
      {/* Beautiful starfield background */}
      <div className="absolute inset-0 bg-gradient-to-b from-slate-900 via-indigo-950 to-slate-900">
        {/* Large bright stars */}
        {Array.from({ length: 50 }, (_, i) => (
          <div
            key={`star-large-${i}`}
            className="absolute w-1 h-1 bg-white rounded-full animate-pulse shadow-lg shadow-white/50"
            style={{
              left: `${Math.random() * 100}%`,
              top: `${Math.random() * 100}%`,
              animationDelay: `${Math.random() * 3}s`,
              animationDuration: `${2 + Math.random() * 2}s`,
              opacity: 0.8 + Math.random() * 0.2
            }}
          />
        ))}
        
        {/* Medium stars */}
        {Array.from({ length: 100 }, (_, i) => (
          <div
            key={`star-medium-${i}`}
            className="absolute w-0.5 h-0.5 bg-blue-200 rounded-full animate-pulse"
            style={{
              left: `${Math.random() * 100}%`,
              top: `${Math.random() * 100}%`,
              animationDelay: `${Math.random() * 4}s`,
              animationDuration: `${3 + Math.random() * 2}s`,
              opacity: 0.6 + Math.random() * 0.3
            }}
          />
        ))}
        
        {/* Small twinkling stars */}
        {Array.from({ length: 200 }, (_, i) => (
          <div
            key={`star-small-${i}`}
            className="absolute w-px h-px bg-indigo-200 rounded-full animate-pulse"
            style={{
              left: `${Math.random() * 100}%`,
              top: `${Math.random() * 100}%`,
              animationDelay: `${Math.random() * 5}s`,
              animationDuration: `${4 + Math.random() * 3}s`,
              opacity: 0.4 + Math.random() * 0.4
            }}
          />
        ))}
        
        {/* Shooting stars */}
        {Array.from({ length: 3 }, (_, i) => (
          <div
            key={`shooting-star-${i}`}
            className="absolute w-20 h-px bg-gradient-to-r from-transparent via-white to-transparent opacity-0"
            style={{
              left: `${20 + Math.random() * 60}%`,
              top: `${10 + Math.random() * 30}%`,
              transform: 'rotate(-30deg)',
              animation: `shootingStar ${8 + Math.random() * 4}s linear infinite`,
              animationDelay: `${Math.random() * 10}s`
            }}
          />
        ))}
      </div>

      {/* Globe Container */}
      <div className="absolute top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2">
        <canvas
          ref={canvasRef}
          className="max-w-full max-h-full"
          style={{ 
            filter: 'drop-shadow(0 0 30px rgba(0, 212, 255, 0.4))',
          }}
        />
        
        {/* Atmospheric glow overlay */}
        <div className="absolute inset-0 rounded-full bg-gradient-to-r from-blue-500/10 via-cyan-500/20 to-blue-500/10
                       animate-pulse pointer-events-none" 
             style={{ animationDuration: '4s' }} />
      </div>
      
      {/* Enhanced floating particles */}
      {Array.from({ length: 30 }, (_, i) => (
        <div
          key={`particle-${i}`}
          className="absolute w-1 h-1 bg-blue-400/80 rounded-full animate-float shadow-sm shadow-blue-400"
          style={{
            left: `${Math.random() * 100}%`,
            top: `${Math.random() * 100}%`,
            animationDelay: `${Math.random() * 5}s`,
            animationDuration: `${3 + Math.random() * 4}s`
          }}
        />
      ))}
      
      {/* Nebula effect */}
      <div className="absolute inset-0 bg-gradient-to-t from-indigo-900/20 via-transparent to-purple-900/20 
                     animate-pulse" style={{ animationDuration: '8s' }} />
      
      {/* Content overlay gradient */}
      <div className="absolute inset-0 bg-gradient-to-t from-slate-900/90 via-slate-900/20 to-slate-900/80" />
    </div>
  );
};