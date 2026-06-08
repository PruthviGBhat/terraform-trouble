// src/components/Navbar.jsx

import React from 'react';
import { Link, NavLink } from 'react-router-dom';
import { useCart } from '../context/CartContext';

const Navbar = ({ onCartClick }) => {
  const { totalItems, totalAmount } = useCart();

  return (
    <nav className="navbar">
      <div className="container navbar-inner">

        <Link to="/" className="navbar-brand">
          🍳 Cloud<span>Kitchen</span>
        </Link>

        <ul className="navbar-links">
          <li><NavLink to="/"       end>Home</NavLink></li>
          <li><NavLink to="/menu"      >Menu</NavLink></li>
          <li><NavLink to="/orders"    >My Orders</NavLink></li>
          <li><NavLink to="/testimonials">Testimonials</NavLink></li>
        </ul>

        <button className="cart-btn" onClick={onCartClick}>
          🛒 Cart
          {totalItems > 0 && (
            <>
              <span className="cart-badge">{totalItems}</span>
              <span style={{ fontSize: '0.85rem', opacity: 0.9 }}>
                ₹{totalAmount.toFixed(0)}
              </span>
            </>
          )}
        </button>

      </div>
    </nav>
  );
};

export default Navbar;