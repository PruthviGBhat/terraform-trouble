import React, { useState } from 'react';
import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import { Toaster } from 'react-hot-toast';
import { CartProvider } from './context/CartContext';
import Navbar from './components/Navbar';
import Footer from './components/Footer';
import Cart from './components/Cart';
import Home from './pages/Home';
import Menu from './pages/Menu';
import Orders from './pages/Orders';
import OrderDetail from './pages/OrderDetail';   // ← ADD THIS
import AIRecommend from './pages/AIRecommend';
import './App.css';
import Testimonials from './pages/Testimonials';

function App() {
  const [cartOpen, setCartOpen] = useState(false);

  return (
    <CartProvider>
      <Router>
        <Toaster
          position="top-right"
          toastOptions={{
            style: {
              fontFamily: 'Poppins, sans-serif',
              borderRadius: '12px',
            },
            success: { iconTheme: { primary: '#FF6B35', secondary: 'white' } },
          }}
        />

        <Navbar onCartClick={() => setCartOpen(true)} />
        {cartOpen && <Cart onClose={() => setCartOpen(false)} />}

        <main>
          <Routes>
            <Route path="/"             element={<Home onCartClick={() => setCartOpen(true)} />} />
            <Route path="/menu"         element={<Menu />} />
            <Route path="/orders"       element={<Orders />} />
            <Route path="/orders/:id"   element={<OrderDetail />} />  {/* ← ADD THIS */}
            <Route path="/testimonials" element={<Testimonials />} />
            <Route path="/ai-recommend" element={<AIRecommend />} />
          </Routes>
        </main>

        <Footer />
      </Router>
    </CartProvider>
  );
}

export default App;
