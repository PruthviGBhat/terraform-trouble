import React, { useState, useEffect, useRef } from 'react';
import toast from 'react-hot-toast';
import syntheticData from '../data/syntheticDemand.json';
import { pipeline, env } from '@xenova/transformers';
import './AIDashboard.css';

// Disable local models to prevent CRA's dev server from intercepting the request 
// and returning the HTML index page (which causes the JSON parse error).
env.allowLocalModels = false;
env.backends.onnx.wasm.wasmPaths = 'https://cdn.jsdelivr.net/npm/@xenova/transformers@2.6.0/dist/';

const AIDashboard = () => {
  const [isModelLoading, setIsModelLoading] = useState(true);
  const [modelLoadingText, setModelLoadingText] = useState('Initializing AI Engine...');
  const [forecasts, setForecasts] = useState([]);
  
  // Extract unique restaurants for the dropdown
  const restaurants = [...new Set(syntheticData.map(item => item.restaurant))];
  const [selectedRestaurant, setSelectedRestaurant] = useState(restaurants[0]);
  
  // We use a ref to hold the pipeline so it isn't re-instantiated
  const generatorRef = useRef(null);

  useEffect(() => {
    // 1. Initialize the LLM (Transformers.js) in the background
    const initAI = async () => {
      try {
        setModelLoadingText('Downloading AI Models (~60MB) into your browser. This only happens once!');
        // We use text2text-generation for FLAN-T5
        generatorRef.current = await pipeline('text2text-generation', 'Xenova/flan-t5-small');
        setIsModelLoading(false);
        toast.success('AI Engine Ready!');
        
        // 2. Run the forecasting sequence once the model is ready
        runForecasting(restaurants[0]);
      } catch (error) {
        console.error("Failed to load Transformers.js", error);
        setModelLoadingText('Failed to load AI Engine. (Are you offline?)');
        toast.error('AI Engine failed to load.');
      }
    };

    initAI();
  }, []);

  // Simulates a time-series forecasting model (like Prophet) using JS math
  const calculatePrediction = (baseDemand, weekendMultiplier) => {
    const today = new Date();
    const isWeekend = today.getDay() === 0 || today.getDay() === 6;
    
    // Base fluctuation +/- 10%
    const fluctuation = baseDemand * (Math.random() * 0.2 - 0.1);
    let prediction = baseDemand + fluctuation;
    
    if (isWeekend) {
      prediction *= weekendMultiplier;
    }
    
    // Add weather bump randomly (simulating external API data)
    const isRaining = Math.random() > 0.7;
    if (isRaining) {
      prediction *= 1.15; // 15% bump for delivery
    }

    return {
      prediction: Math.round(prediction),
      isWeekend,
      isRaining
    };
  };

  const runForecasting = async (restaurantName) => {
    const results = [];
    
    // Filter data for the specific restaurant
    const filteredData = syntheticData.filter(item => item.restaurant === restaurantName);
    
    for (const item of filteredData) {
      const { prediction, isWeekend, isRaining } = calculatePrediction(item.baseDemand, item.weekendMultiplier);
      
      let risk = "OPTIMAL";
      let action = "No action needed";
      
      if (prediction > item.inventory) {
        risk = "UNDERSTOCK";
        action = `Prepare +${prediction - item.inventory} units immediately.`;
      } else if (prediction < item.inventory - 20) {
        // Arbitrary threshold for overstock
        risk = "OVERSTOCK";
        action = "Stop preparation. Run promotional discount.";
      }

      results.push({
        ...item,
        prediction,
        risk,
        action,
        context: { isWeekend, isRaining },
        explanation: "Generating AI insight..."
      });
    }
    
    setForecasts(results);
    generateExplanations(results);
  };

  const handleRestaurantChange = (e) => {
    const newRestaurant = e.target.value;
    setSelectedRestaurant(newRestaurant);
    runForecasting(newRestaurant);
  };

  const generateExplanations = async (initialResults) => {
    if (!generatorRef.current) return;

    const newForecasts = [...initialResults];

    for (let i = 0; i < newForecasts.length; i++) {
      const item = newForecasts[i];
      
      // We construct a strict prompt for the T5 model
      const prompt = `Context: Today is ${item.context.isWeekend ? 'the weekend' : 'a weekday'} and it is ${item.context.isRaining ? 'raining' : 'sunny'}. We predicted ${item.prediction} orders of ${item.name} at ${item.restaurant}. We only have ${item.inventory} in inventory. The risk is ${item.risk}. Briefly explain why we have an ${item.risk} risk.`;
      
      try {
        const output = await generatorRef.current(prompt, {
          max_new_tokens: 40,
          temperature: 0.7,
        });
        
        newForecasts[i].explanation = output[0].generated_text || "AI Explanation unavailable.";
      } catch (err) {
        console.error("LLM Generation error:", err);
        newForecasts[i].explanation = "Error generating insight.";
      }
      
      // Update state item by item so the UI feels alive
      setForecasts([...newForecasts]);
    }
  };

  return (
    <div className="ai-dashboard-container">
      <div className="ai-dashboard-header">
        <h1>AI Demand Forecaster 📊</h1>
        <p>100% Client-Side AI. Powered by Transformers.js & WebAssembly.</p>
      </div>

      {isModelLoading ? (
        <div className="ai-loading-box">
          <div className="spinner"></div>
          <h2>{modelLoadingText}</h2>
          <p>Please wait while WebAssembly initializes the neural network...</p>
        </div>
      ) : (
        <div className="ai-table-container">
          <div className="ai-controls">
            <div className="restaurant-selector">
              <label>Select Kitchen: </label>
              <select value={selectedRestaurant} onChange={handleRestaurantChange} className="restaurant-dropdown">
                {restaurants.map(r => <option key={r} value={r}>{r}</option>)}
              </select>
            </div>
            <button onClick={() => runForecasting(selectedRestaurant)} className="btn-primary">
              🔄 Recalculate Forecast
            </button>
          </div>
          
          <table className="ai-table">
            <thead>
              <tr>
                <th>Menu Item</th>
                <th>Current Inventory</th>
                <th>Predicted Demand</th>
                <th>Risk Status</th>
                <th>Recommended Action</th>
                <th>AI Insight</th>
              </tr>
            </thead>
            <tbody>
              {forecasts.map((item) => (
                <tr key={item.id} className={`risk-row ${item.risk.toLowerCase()}`}>
                  <td className="item-name">{item.name}</td>
                  <td className="metric">{item.inventory}</td>
                  <td className="metric highlight">{item.prediction}</td>
                  <td>
                    <span className={`badge badge-${item.risk.toLowerCase()}`}>
                      {item.risk}
                    </span>
                  </td>
                  <td>{item.action}</td>
                  <td className="explanation">
                    {item.explanation === "Generating AI insight..." ? (
                      <span className="pulsing-text">Generating...</span>
                    ) : (
                      item.explanation
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
};

export default AIDashboard;
