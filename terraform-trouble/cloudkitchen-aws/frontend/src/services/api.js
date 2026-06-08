// src/services/api.js

import axios from 'axios';

const API_BASE = '';

const api = axios.create({
  baseURL: `${API_BASE}/api`,
  timeout: 10000,
  headers: { 'Content-Type': 'application/json' },
});

// Response interceptor
api.interceptors.response.use(
  (response) => response.data,
  (error) => {
    const message = error.response?.data?.message || 'Something went wrong!';
    return Promise.reject(new Error(message));
  }
);

// ── Menu APIs ──────────────────────────────────────────────
export const menuAPI = {
  getAll:          ()         => api.get('/menu'),
  getById:         (id)       => api.get(`/menu/${id}`),
  getByCategory:   (catId)    => api.get(`/menu/category/${catId}`),
  search:          (keyword)  => api.get(`/menu/search?keyword=${keyword}`),
  getVegItems:     ()         => api.get('/menu/veg'),
};

// ── Category APIs ──────────────────────────────────────────
export const categoryAPI = {
  getAll: () => api.get('/categories'),
};

// ── Order APIs ─────────────────────────────────────────────
export const orderAPI = {
  place:        (orderData) => api.post('/orders', orderData),
  getById:      (id)        => api.get(`/orders/${id}`),
  trackByEmail: (email)     => api.get(`/orders/track?email=${email}`),
};

export default api;
