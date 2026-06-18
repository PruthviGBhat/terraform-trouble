// src/pages/AIDashboard.jsx
// Demand Forecasting Dashboard
// Predictions factor in: time-of-day, day-of-week, weekend surge, and recent trend.
// AI narrative insights are fetched from the backend /api/recommend_forecast endpoint.

import React, { useState, useEffect, useCallback } from 'react';
import allData from '../data/syntheticDemand.json';
import './AIDashboard.css';

const KITCHENS   = [...new Set(allData.map(d => d.kitchen))];
const DAY_NAMES  = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

// ── Demand prediction ────────────────────────────────────────────────────────
// Combines day-of-week, time-of-day, and recent trend into a single demand estimate.
const predictDemand = (item) => {
  const now        = new Date();
  const day        = now.getDay();
  const hour       = now.getHours();
  const isWeekend  = day === 0 || day === 6;

  // Service-period classification and time multiplier
  let period, timeFactor;
  if (hour >= 7 && hour < 11) {
    period     = 'Morning Prep';
    timeFactor = 0.55;
  } else if (hour >= 11 && hour <= 14) {
    period     = 'Lunch Rush';
    timeFactor = item.lunchFactor ?? 1.3;
  } else if (hour >= 15 && hour <= 17) {
    period     = 'Afternoon Lull';
    timeFactor = 0.65;
  } else if (hour >= 18 && hour <= 21) {
    period     = 'Dinner Service';
    timeFactor = item.dinnerFactor ?? 1.5;
  } else if (hour >= 22 || hour < 7) {
    period     = 'Off-Peak';
    timeFactor = 0.25;
  } else {
    period     = 'Active';
    timeFactor = 1.0;
  }

  // Trend multiplier — 3-day rolling trend encoded in data
  const trendMultiplier =
    item.trend === 'rising'  ? 1.12 :
    item.trend === 'falling' ? 0.88 : 1.0;

  // Small deterministic variance per item (avoids all bars being identical)
  const hash     = [...item.id].reduce((a, c) => (a * 31 + c.charCodeAt(0)) % 100, 0);
  const variance = Math.floor(hash * 0.08) - 4;

  let demand = item.baseDemand;
  if (isWeekend) demand = Math.round(demand * item.weekendMultiplier);
  demand = Math.round(demand * timeFactor * trendMultiplier) + variance;

  return {
    demand:    Math.max(1, demand),
    isWeekend,
    dayName:   DAY_NAMES[day],
    period,
    trend:     item.trend ?? 'stable',
    timeFactor,
  };
};

// ── Risk computation ─────────────────────────────────────────────────────────
// Perishability influences overstock urgency — a 2-hour item going stale is
// more critical than one that keeps for 24 hours.
const computeRisk = (inventory, demand, item) => {
  const gap    = demand - inventory;
  const excess = inventory - demand;

  if (gap > 10) {
    const severity = gap > 25 ? 'critically' : 'significantly';
    return {
      risk:   'UNDERSTOCK',
      action: `Demand ${severity} exceeds stock by ${gap} units — prep immediately.`,
    };
  }
  if (excess > 20) {
    const perishSoon = (item?.perishabilityHours ?? 24) <= 3;
    return {
      risk:   'OVERSTOCK',
      action: perishSoon
        ? `${excess} excess units spoil in ${item.perishabilityHours}h — run flash deal NOW.`
        : `${excess} surplus units — offer 15% discount to clear before close.`,
    };
  }
  return { risk: 'OPTIMAL', action: 'Inventory well-matched to expected demand.' };
};

// ── Row builder ───────────────────────────────────────────────────────────────
const buildRows = (kitchen) =>
  allData
    .filter(d => d.kitchen === kitchen)
    .map(item => {
      const { demand, isWeekend, dayName, period, trend } = predictDemand(item);
      const { risk, action } = computeRisk(item.inventory, demand, item);
      return { ...item, demand, isWeekend, dayName, period, trend, risk, action, insight: null };
    });

// ── Trend display helpers ─────────────────────────────────────────────────────
const TREND_ICON  = { rising: '↑', stable: '→', falling: '↓' };
const TREND_COLOR = { rising: '#27AE60', stable: '#7F8C8D', falling: '#E74C3C' };


// ── Component ─────────────────────────────────────────────────────────────────
const AIDashboard = () => {
  const [kitchen,   setKitchen]   = useState(KITCHENS[0]);
  const [rows,      setRows]      = useState(() => buildRows(KITCHENS[0]));
  const [aiLoading, setAiLoading] = useState(false);
  const [aiOnline,  setAiOnline]  = useState(null); // null=unknown, true, false

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

  useEffect(() => { fetchInsights(rows); }, []); // eslint-disable-line

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
            &nbsp;·&nbsp;
            <span className="period-badge">{today?.period}</span>
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
        {aiLoading && '⏳ Fetching AI insights from Ollama…'}
        {!aiLoading && aiOnline === true  && '✅ AI insights powered by open-source LLM via LangChain + Ollama'}
        {!aiLoading && aiOnline === false && '⚠️ AI service warming up — rule-based insights shown. Retry in ~15 min after deploy.'}
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
              <th>Category</th>
              <th>Stock</th>
              <th>Predicted Orders</th>
              <th>Demand Bar</th>
              <th>Trend</th>
              <th>Risk</th>
              <th>Action</th>
              <th>AI Insight</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(row => {
              const pct      = Math.min(100, Math.round((row.demand / (row.inventory || 1)) * 100));
              const barColor = row.risk === 'UNDERSTOCK' ? '#E74C3C'
                             : row.risk === 'OVERSTOCK'  ? '#F39C12'
                             : '#27AE60';
              const trendColor = TREND_COLOR[row.trend] || '#7F8C8D';
              const trendIcon  = TREND_ICON[row.trend]  || '→';

              return (
                <tr key={row.id} className={`risk-row risk-${row.risk.toLowerCase()}`}>
                  <td className="item-name">{row.name}</td>
                  <td className="category-cell">{row.category}</td>
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
                  <td className="trend-cell">
                    <span style={{ color: trendColor, fontWeight: 600, fontSize: '1.1rem' }}>
                      {trendIcon}
                    </span>
                    &nbsp;
                    <span style={{ color: trendColor, fontSize: '0.78rem' }}>{row.trend}</span>
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
        Demand factors: day-of-week × time-of-day ({today?.period}) × 3-day trend ·
        Weekend surge applied automatically ·
        AI insights by open-source LLM (Ollama) via LangChain on the CloudKitchen AI service
      </p>
    </div>
  );
};

export default AIDashboard;
