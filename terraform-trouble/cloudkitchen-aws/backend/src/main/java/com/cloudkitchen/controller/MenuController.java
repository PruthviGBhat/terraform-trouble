// backend/src/main/java/com/cloudkitchen/controller/MenuController.java

package com.cloudkitchen.controller;

import com.cloudkitchen.dto.ApiResponse;
import com.cloudkitchen.model.MenuItem;
import com.cloudkitchen.service.MenuService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.util.List;

@RestController
@RequestMapping("/api/menu")
@RequiredArgsConstructor
public class MenuController {

    private final MenuService menuService;

    @GetMapping
    public ResponseEntity<ApiResponse<List<MenuItem>>> getAllMenuItems() {
        List<MenuItem> items = menuService.getAllAvailableItems();
        return ResponseEntity.ok(
                ApiResponse.success(items, "Menu items fetched successfully"));
    }

    @GetMapping("/{id}")
    public ResponseEntity<ApiResponse<MenuItem>> getMenuItemById(@PathVariable Long id) {
        MenuItem item = menuService.getItemById(id);
        return ResponseEntity.ok(
                ApiResponse.success(item, "Menu item fetched successfully"));
    }

    @GetMapping("/category/{categoryId}")
    public ResponseEntity<ApiResponse<List<MenuItem>>> getItemsByCategory(
            @PathVariable Long categoryId) {
        List<MenuItem> items = menuService.getItemsByCategory(categoryId);
        return ResponseEntity.ok(
                ApiResponse.success(items, "Items by category fetched successfully"));
    }

    @GetMapping("/search")
    public ResponseEntity<ApiResponse<List<MenuItem>>> searchMenu(
            @RequestParam String keyword) {
        List<MenuItem> items = menuService.searchItems(keyword);
        return ResponseEntity.ok(
                ApiResponse.success(items, "Search results fetched successfully"));
    }

    @GetMapping("/veg")
    public ResponseEntity<ApiResponse<List<MenuItem>>> getVegItems() {
        List<MenuItem> items = menuService.getVegItems();
        return ResponseEntity.ok(
                ApiResponse.success(items, "Veg items fetched successfully"));
    }
}