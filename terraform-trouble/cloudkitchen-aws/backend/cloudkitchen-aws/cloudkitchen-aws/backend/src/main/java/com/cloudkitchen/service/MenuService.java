// backend/src/main/java/com/cloudkitchen/service/MenuService.java

package com.cloudkitchen.service;

import com.cloudkitchen.model.MenuItem;
import com.cloudkitchen.repository.MenuItemRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import java.util.List;

@Service
@RequiredArgsConstructor
public class MenuService {

    private final MenuItemRepository menuItemRepository;

    public List<MenuItem> getAllAvailableItems() {
        return menuItemRepository.findByIsAvailableTrue();
    }

    public List<MenuItem> getItemsByCategory(Long categoryId) {
        return menuItemRepository.findByCategoryIdAndIsAvailableTrue(categoryId);
    }

    public List<MenuItem> searchItems(String keyword) {
        return menuItemRepository.searchByKeyword(keyword);
    }

    public List<MenuItem> getVegItems() {
        return menuItemRepository.findByIsVegTrueAndIsAvailableTrue();
    }

    public MenuItem getItemById(Long id) {
        return menuItemRepository.findById(id)
                .orElseThrow(() -> new RuntimeException("Menu item not found with id: " + id));
    }
}