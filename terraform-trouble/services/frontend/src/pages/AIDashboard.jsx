// src/pages/AIDashboard.jsx
// Demand Forecasting Dashboard — no client-side model download.
// Predictions are deterministic (based on day-of-week).
// AI insights are fetched from the backend /api/recommend_forecast endpoint.

import React, { useState, useEffect, useCallback } from 'react';
import toast from 'react-hot-toast';
import allData from '../data/syntheticDemand.json';
import './AIDashboard.css';

const KITCHENS = [...new Set(allData.map(d => d.kitchen))];

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

// Deterministic demand prediction — same result for the same item on the same day.
const predictDemand = (item) => {
  const day      = new Date().getDay();
  const isWeekend = day === 0 || day === 6;
  // Pseudo-variance from item id hash so each item varies slightly
  const hash     = [...item.id].reduce((a, c) => (a * 31 + c.charCodeAt(0)) % 100, 0);
  const variance = Math.floor(hash * 0.18) - 9; // -9 to +9
  let demand     = item.baseDemand + variance;
  if (isWeekend) demand = Math.round(demand * item.weekendMultiplier);
  return { demand: Math.max(1, Math.round(demand)), isWeekend, dayName: DAY_NAMES[day] };
};

const computeRisk = (inventory, demand) => {
  const gap = demand - inventory;
  if (gap > 10)               return { risk: 'UNDERSTOCK', action: `Prep ${gap} more units before service.` };
  if (inventory - demand > 20) return { risk: 'OVERSTOCK',  action: 'Offer a 15% flash deal to move excess.' };
  return                              { risk: 'OPTIMAL',    action: 'Inventory well-matched to demand.' };
};

const buildRows = (kitchen) =>
  allData
    .filter(d => d.kitchen === kitchen)
    .map(item => {
      const { demand, isWeekend, dayName } = predictDemand(item);
      const { risk, action }               = computeRisk(item.inventory, demand);
      return { ...item, demand, isWeekend, dayName, risk, action, insight: null };
    });

const AIDashboard = () => {
  const [kitchen,     setKitchen]     = useState(KITCHENS[0]);
  const [rows,        setRows]        = useState(() => buildRows(KITCHENS[0]));
  const [aiLoading,   setAiLoading]   = useState(false);
  const [aiOnline,    setAiOnline]    = useState(null); // null=unknown, true, false

  const fetchInsights = useCallback(async (currentRows) => {
    setAiLoading(true);
    try {
      const payload = currentRows.map(r => ({
        id:               r.id,
        name:             r.name,
        kitchen:          r.kitchen,
        inventory:        r.inventory,
        predicted_demand: r.demand,
      }));

      const res = await fetch('/api/recommend_forecast', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ items: payload }),
      });

      if (!res.ok) throw new Error('offline');
      const data = await res.json();
      setAiOnline(true);

      setRows(prev =>
        prev.map(row => {
          const hit = (data.insights || []).find(i => i.id === row.id);
          return hit ? { ...row, insight: hit.insight } : row;
        })
      );
    } catch {
      setAiOnline(false);
    } finally {
      setAiLoading(false);
    }
  }, []);

  const loadKitchen = (name) => {
    const fresh = buildRows(name);
    setKitchen(name);
    setRows(fresh);
    fetchInsights(fresh);
  };

  useEffect(() => {
    fetchInsights(rows);
  }, []); // eslint-disable-line

  const today = rows[0];

  return (
    <div className="dash-container">

      {/* Header */}
      <div className="dash-header">
        <div>
          <h1>AI Demand Forecaster 📊</h1>
          <p>
            Real-time inventory risk analysis · Today is&nbsp;
            <strong>{today?.dayName}</strong>
            {today?.isWeekend && <span className="weekend-badge">Weekend Surge</span>}
          </p>
        </div>
        <div className="dash-controls">
          <select
            className="kitchen-select"
            value={kitchen}
            onChange={e => loadKitchen(e.target.value)}
          >
            {KITCHENS.map(k => <option key={k} value={k}>{k}</option>)}
          </select>
          <button className="btn btn-outline" onClick={() => loadKitchen(kitchen)}>
            🔄 Refresh
          </button>
        </div>
      </div>

      {/* AI status bar */}
      <div className={`ai-status-bar ${aiOnline === false ? 'offline' : aiOnline ? 'online' : 'loading'}`}>
        {aiLoading && '⏳ Fetching AI insights from the server…'}
        {!aiLoading && aiOnline === true  && '✅ AI insights loaded from CloudKitchen AI service'}
        {!aiLoading && aiOnline === false && '⚠️ AI service is warming up — rule-based insights shown. Try refreshing in ~15 min after deploy.'}
      </div>

      {/* Summary cards */}
      <div className="summary-strip">
        {['UNDERSTOCK', 'OPTIMAL', 'OVERSTOCK'].map(level => {
          const count = rows.filter(r => r.risk === level).length;
          return (
            <div key={level} className={`summary-card summary-${level.toLowerCase()}`}>
              <span className="summary-count">{count}</span>
              <span className="summary-label">{level}</span>
            </div>
          );
        })}
      </div>

      {/* Table */}
      <div className="dash-table-wrap">
        <table className="dash-table">
          <thead>
            <tr>
              <th>Menu Item</th>
              <th>Stock</th>
              <th>Predicted Orders</th>
              <th>Demand Bar</th>
              <th>Risk</th>
              <th>Action</th>
              <th>AI Insight</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(row => {
              const pct   = Math.min(100, Math.round((row.demand / (row.inventory || 1)) * 100));
              const barColor = row.risk === 'UNDERSTOCK' ? '#E74C3C'
                             : row.risk === 'OVERSTOCK'  ? '#F39C12'
                             : '#27AE60';
              return (
                <tr key={row.id} className={`risk-row risk-${row.risk.toLowerCase()}`}>
                  <td className="item-name">{row.name}</td>
                  <td className="metric">{row.inventory}</td>
                  <td className="metric highlight">{row.demand}</td>
                  <td className="bar-cell">
                    <div className="demand-bar-bg">
                      <div
                        className="demand-bar-fill"
                        style={{ width: `${pct}%`, background: barColor }}
                      />
                    </div>
                    <span className="bar-pct" style={{ color: barColor }}>{pct}%</span>
                  </td>
                  <td>
                    <span className={`badge badge-${row.risk.toLowerCase()}`}>{row.risk}</span>
                  </td>
                  <td className="action-cell">{row.action}</td>
                  <td className="insight-cell">
                    {row.insight
                      ? row.insight
                      : aiLoading
                        ? <span className="pulsing">Generating…</span>
                        : <span className="rule-insight">{row.action}</span>
                    }
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <p className="dash-footnote">
        Predictions are deterministic per day-of-week · Weekend multipliers applied automatically ·
        AI insights powered by FLAN-T5 on the CloudKitchen AI service
      </p>
    </div>
  );
};

export default AIDashboard;
