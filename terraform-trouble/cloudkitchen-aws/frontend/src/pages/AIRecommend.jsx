import React, { useState } from 'react';
import toast from 'react-hot-toast';
import './AIRecommend.css';

const AIRecommend = () => {
  const [query, setQuery] = useState('');
  const [preferences, setPreferences] = useState({
    vegetarian: false,
    vegan: false,
    lactoseIntolerant: false
  });
  const [customDiet, setCustomDiet] = useState('');
  const [numOptions, setNumOptions] = useState(3);
  const [loading, setLoading] = useState(false);
  const [recommendations, setRecommendations] = useState([]);

  const handleCheckboxChange = (e) => {
    const { name, checked } = e.target;
    setPreferences(prev => ({ ...prev, [name]: checked }));
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!query.trim()) {
      toast.error('Please enter what you are craving!');
      return;
    }

    setLoading(true);
    setRecommendations([]);

    // Map UI checkboxes to API format
    const prefList = [];
    let allergyList = [];
    if (preferences.vegetarian) prefList.push("vegetarian");
    if (preferences.vegan) prefList.push("vegan");
    if (preferences.lactoseIntolerant) allergyList.push("contains_dairy");

    // Add custom dietary exclusions
    if (customDiet.trim()) {
        const customTags = customDiet.split(',').map(tag => tag.trim().toLowerCase()).filter(tag => tag.length > 0);
        allergyList = [...allergyList, ...customTags];
    }

    try {
      // 1. Update preferences (we use an anonymous user session for this demo)
      await fetch('/api/update_user_preferences', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          user_id: "anon_user_1",
          preferences: prefList,
          allergies: allergyList
        })
      });

      // 2. Fetch recommendations
      const res = await fetch('/api/recommend', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          user_id: "anon_user_1",
          query: query,
          top_k: Number(numOptions)
        })
      });

      if (!res.ok) throw new Error('Failed to fetch recommendations');
      const data = await res.json();
      
      if (data.recommendations && data.recommendations.length > 0) {
        setRecommendations(data.recommendations);
        toast.success('AI Chef found some matches!');
      } else {
        toast.error('No safe matches found for those restrictions.');
      }
    } catch (error) {
      console.error(error);
      toast.error('AI Recommender is currently offline. Please wait 10 mins if you just deployed.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="ai-page container">
      <div className="ai-header">
        <h1>Ask the AI Chef 🤖</h1>
        <p>Tell us what you're craving, and our AI will find the perfect dish while respecting your diet!</p>
      </div>

      <form className="ai-form" onSubmit={handleSubmit}>
        <div className="form-group">
          <label>What are you craving?</label>
          <input 
            type="text" 
            placeholder="e.g., I want something spicy and hearty..." 
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>

        <div className="form-group diet-options">
          <label>Standard Restrictions:</label>
          <div className="checkboxes">
            <label>
              <input type="checkbox" name="vegetarian" checked={preferences.vegetarian} onChange={handleCheckboxChange} />
              Vegetarian
            </label>
            <label>
              <input type="checkbox" name="vegan" checked={preferences.vegan} onChange={handleCheckboxChange} />
              Vegan
            </label>
            <label>
              <input type="checkbox" name="lactoseIntolerant" checked={preferences.lactoseIntolerant} onChange={handleCheckboxChange} />
              Lactose Intolerant (No Dairy)
            </label>
          </div>
        </div>

        <div className="form-group">
          <label>Custom Exclusions (comma-separated tags):</label>
          <input 
            type="text" 
            placeholder="e.g., contains_nuts, contains_gluten, high_calorie" 
            value={customDiet}
            onChange={(e) => setCustomDiet(e.target.value)}
          />
          <small className="help-text">Any food with these tags will be strictly filtered out by the AI.</small>
        </div>

        <div className="form-group">
            <label>Number of Options:</label>
            <select value={numOptions} onChange={(e) => setNumOptions(e.target.value)}>
                <option value="1">1 Option</option>
                <option value="2">2 Options</option>
                <option value="3">3 Options</option>
                <option value="5">5 Options</option>
                <option value="10">10 Options</option>
            </select>
        </div>

        <button type="submit" className="btn-primary" disabled={loading}>
          {loading ? 'Consulting the Chef...' : 'Get Recommendations'}
        </button>
      </form>

      {recommendations.length > 0 && (
        <div className="ai-results">
          <h2>Chef's Top Picks</h2>
          <div className="recommendation-list">
            {recommendations.map((rec, idx) => (
              <div key={idx} className="recommendation-card">
                <h3>{rec.food_item.name}</h3>
                <span className="category-badge">{rec.food_item.category}</span>
                <p className="desc">{rec.food_item.description}</p>
                <div className="ai-reason">
                  <strong>🤖 AI Says:</strong> {rec.reason}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

export default AIRecommend;
