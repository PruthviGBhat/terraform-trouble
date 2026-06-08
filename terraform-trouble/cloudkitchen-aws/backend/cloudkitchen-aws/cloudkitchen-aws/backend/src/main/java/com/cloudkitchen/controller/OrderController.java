// backend/src/main/java/com/cloudkitchen/controller/OrderController.java

package com.cloudkitchen.controller;

import com.cloudkitchen.dto.*;
import com.cloudkitchen.model.Order;
import com.cloudkitchen.service.OrderService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
import java.util.List;

@RestController
@RequestMapping("/api/orders")
@RequiredArgsConstructor
public class OrderController {

    private final OrderService orderService;

    @PostMapping
    public ResponseEntity<ApiResponse<Order>> placeOrder(
            @Valid @RequestBody OrderRequest request) {
        Order order = orderService.placeOrder(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(
                ApiResponse.success(order, "Order placed successfully! 🎉"));
    }

    @GetMapping("/{id}")
    public ResponseEntity<ApiResponse<Order>> getOrderById(@PathVariable Long id) {
        Order order = orderService.getOrderById(id);
        return ResponseEntity.ok(
                ApiResponse.success(order, "Order fetched successfully"));
    }

    @GetMapping("/track")
    public ResponseEntity<ApiResponse<List<Order>>> trackOrders(
            @RequestParam String email) {
        List<Order> orders = orderService.getOrdersByEmail(email);
        return ResponseEntity.ok(
                ApiResponse.success(orders, "Orders fetched successfully"));
    }

    @GetMapping
    public ResponseEntity<ApiResponse<List<Order>>> getAllOrders() {
        List<Order> orders = orderService.getAllOrders();
        return ResponseEntity.ok(
                ApiResponse.success(orders, "All orders fetched successfully"));
    }

    @PatchMapping("/{id}/status")
    public ResponseEntity<ApiResponse<Order>> updateStatus(
            @PathVariable Long id,
            @RequestParam String status) {
        Order order = orderService.updateOrderStatus(id, status);
        return ResponseEntity.ok(
                ApiResponse.success(order, "Order status updated successfully"));
    }
}