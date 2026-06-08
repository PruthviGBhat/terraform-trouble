// backend/src/main/java/com/cloudkitchen/repository/CategoryRepository.java

package com.cloudkitchen.repository;

import com.cloudkitchen.model.Category;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface CategoryRepository extends JpaRepository<Category, Long> {}