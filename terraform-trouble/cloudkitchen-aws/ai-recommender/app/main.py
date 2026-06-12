from fastapi import FastAPI, HTTPException
from typing import List

from app.models import (
    UserProfile, RecommendationRequest, 
    RecommendationResponse, RecommendationResult
)
from app.database import db
from app.vector_store import vector_store
from app.rules import filter_food_items
from app.recommender import recommender_llm

app = FastAPI(title="CloudKitchen AI Recommender", version="1.0.0")

@app.on_event("startup")
async def startup_event():
    # Initialize Vector DB with all food items from the mock database on startup
    all_food = db.get_all_food()
    vector_store.initialize_db(all_food)
    print("Vector database initialized with menu items.")

@app.post("/api/update_user_preferences")
async def update_user_preferences(profile: UserProfile):
    db.update_user(profile.user_id, profile.preferences, profile.allergies)
    return {"message": f"User {profile.user_id} preferences updated successfully."}

@app.post("/api/recommend", response_model=RecommendationResponse)
async def get_recommendations(req: RecommendationRequest):
    user = db.get_user(req.user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    all_food = db.get_all_food()
    
    # 1. Rule-Based Filtering (Safety First)
    safe_food = filter_food_items(user, all_food)
    if not safe_food:
        return RecommendationResponse(user_id=req.user_id, recommendations=[])

    safe_food_ids = [f.id for f in safe_food]

    # 2. Vector Search (Contextual Similarity)
    ranked_food_ids = vector_store.search(
        query=req.query, 
        safe_food_ids=safe_food_ids, 
        top_k=req.top_k
    )

    # 3. LLM Reasoning Layer
    recommendations = []
    for f_id in ranked_food_ids:
        food_item = db.get_food_by_id(f_id)
        if food_item:
            reason = recommender_llm.generate_reason(food_item, user, req.query)
            recommendations.append(
                RecommendationResult(
                    food_item=food_item,
                    reason=reason
                )
            )

    return RecommendationResponse(
        user_id=req.user_id,
        recommendations=recommendations
    )
