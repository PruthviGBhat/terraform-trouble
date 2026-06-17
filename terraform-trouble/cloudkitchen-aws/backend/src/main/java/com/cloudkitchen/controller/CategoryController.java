// backend/src/main/java/com/cloudkitchen/controller/CategoryController.java

package com.cloudkitchen.controller;

import com.cloudkitchen.dto.ApiResponse;
import com.cloudkitchen.model.Category;
import com.cloudkitchen.repository.CategoryRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.util.List;

@RestController
@RequestMapping("/api/categories")
@RequiredArgsConstructor
public class CategoryController {

    private final CategoryRepository categoryRepository;

    @GetMapping
    public ResponseEntity<ApiResponse<List<Category>>> getAllCategories() {
        List<Category> categories = categoryRepository.findAll();
        return ResponseEntity.ok(
                ApiResponse.success(categories, "Categories fetched successfully"));
    }
}