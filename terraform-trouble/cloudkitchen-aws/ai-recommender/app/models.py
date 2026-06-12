from pydantic import BaseModel
from typing import List, Optional

class FoodItem(BaseModel):
    id: str
    name: str
    description: str
    ingredients: List[str]
    category: str
    dietary_tags: List[str]

class UserProfile(BaseModel):
    user_id: str
    preferences: List[str]
    allergies: List[str]

class RecommendationRequest(BaseModel):
    user_id: str
    query: Optional[str] = "I'm hungry, recommend me something."
    top_k: Optional[int] = 3

class RecommendationResult(BaseModel):
    food_item: FoodItem
    reason: str

class RecommendationResponse(BaseModel):
    user_id: str
    recommendations: List[RecommendationResult]
