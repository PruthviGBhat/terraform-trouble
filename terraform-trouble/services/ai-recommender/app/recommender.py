from transformers import pipeline
from app.models import FoodItem, UserProfile, ForecastItem

class RecommenderLLM:
    def __init__(self):
        # flan-t5-small: lightweight, CPU-friendly, good at instruction following
        self.pipe = pipeline(
            "text2text-generation",
            model="google/flan-t5-small",
            max_length=80,
            truncation=True
        )

    def generate_reason(self, food: FoodItem, user: UserProfile, query: str) -> str:
        prefs = ", ".join(user.preferences) if user.preferences else "no special diet"
        algs  = ", ".join(user.allergies)   if user.allergies   else "no allergies"

        prompt = (
            f"User wants: '{query}'. Diet: {prefs}. Avoids: {algs}. "
            f"Food: {food.name} — {food.description} "
            f"In one short sentence, explain why this food is a good match:"
        )

        try:
            result = self.pipe(prompt)[0]["generated_text"].strip()
            if len(result) > 12 and result.lower() not in (prompt.lower(), ""):
                return result
        except Exception:
            pass

        return self._template_reason(food, user, query)

    def _template_reason(self, food: FoodItem, user: UserProfile, query: str) -> str:
        tags = set(food.dietary_tags)
        q    = query.lower()
        reasons = []

        if "vegan" in user.preferences and "vegan" in tags:
            reasons.append("it's 100% plant-based")
        elif "vegetarian" in user.preferences and ("vegetarian" in tags or "vegan" in tags):
            reasons.append("it's fully vegetarian")

        if "contains_dairy" in user.allergies and "contains_dairy" not in tags:
            reasons.append("it's completely dairy-free")
        if "contains_gluten" in user.allergies and "contains_gluten" not in tags:
            reasons.append("it's gluten-free")
        if "contains_nuts" in user.allergies and "contains_nuts" not in tags:
            reasons.append("it contains no nuts")

        if any(w in q for w in ["spicy", "hot", "fiery"]) and "spicy" in tags:
            reasons.append("it delivers the spicy kick you're after")
        if any(w in q for w in ["light", "healthy", "diet", "low cal"]) and "healthy" in tags:
            reasons.append("it's a nutritious low-calorie option")
        if any(w in q for w in ["hearty", "filling", "rich", "heavy"]) and food.category == "Main Course":
            reasons.append("it's a hearty main course that will fill you up")
        if any(w in q for w in ["sweet", "dessert", "indulge"]) and food.category == "Dessert":
            reasons.append("it perfectly satisfies your sweet craving")

        if reasons:
            return f"Great match — {' and '.join(reasons[:2])}, aligned with your preferences."
        return f"A safe and delicious {food.category.lower()} that suits your dietary profile perfectly."

    def generate_forecast_insight(self, item: ForecastItem, risk: str) -> str:
        gap = abs(item.predicted_demand - item.inventory)

        prompt = (
            f"Kitchen inventory: {item.inventory} portions of {item.name}. "
            f"Predicted orders: {item.predicted_demand}. "
            f"Inventory risk level: {risk}. "
            f"Provide one short actionable recommendation:"
        )

        try:
            result = self.pipe(prompt)[0]["generated_text"].strip()
            if len(result) > 12:
                return result
        except Exception:
            pass

        if risk == "UNDERSTOCK":
            return f"Demand exceeds stock by {gap} units — prep more {item.name} immediately to avoid running out."
        if risk == "OVERSTOCK":
            return f"Stock exceeds demand by {gap} units — consider a limited-time offer to drive orders before spoilage."
        return f"Inventory and demand are well-balanced at ~{item.predicted_demand} orders. Maintain current prep levels."

recommender_llm = RecommenderLLM()
