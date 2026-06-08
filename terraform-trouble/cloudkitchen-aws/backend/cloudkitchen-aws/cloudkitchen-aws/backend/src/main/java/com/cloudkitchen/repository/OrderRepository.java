// backend/src/main/java/com/cloudkitchen/repository/OrderRepository.java

package com.cloudkitchen.repository;

import com.cloudkitchen.model.Order;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;
import java.util.List;

@Repository
public interface OrderRepository extends JpaRepository<Order, Long> {

    List<Order> findByCustomerEmailOrderByCreatedAtDesc(String email);

    List<Order> findByStatusOrderByCreatedAtDesc(String status);

    List<Order> findAllByOrderByCreatedAtDesc();
}