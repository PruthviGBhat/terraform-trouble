from transformers import pipeline
from langchain.llms import HuggingFacePipeline
from langchain.prompts import PromptTemplate
from app.models import FoodItem, UserProfile

class RecommenderLLM:
    def __init__(self):
        # We use flan-t5-small as it is extremely lightweight, CPU friendly, 
        # and capable of following simple instructions for generation.
        pipe = pipeline(
            "text2text-generation",
            model="google/flan-t5-small",
            max_length=50,
            truncation=True
        )
        self.llm = HuggingFacePipeline(pipeline=pipe)
        
        self.prompt_template = PromptTemplate(
            input_variables=["food_name", "food_desc", "preferences", "allergies", "query"],
            template=(
                "User asks: '{query}'. "
                "User is: {preferences}. "
                "User allergies: {allergies}. "
                "Food: {food_name} ({food_desc}). "
                "In one short sentence, explain why this food is a safe and good recommendation for the user."
            )
        )

    def generate_reason(self, food: FoodItem, user: UserProfile, query: str) -> str:
        prefs = ", ".join(user.preferences) if user.preferences else "None"
        algs = ", ".join(user.allergies) if user.allergies else "None"
        
        prompt = self.prompt_template.format(
            food_name=food.name,
            food_desc=food.description,
            preferences=prefs,
            allergies=algs,
            query=query
        )
        
        # Generate the reason using the local LLM
        reason = self.llm(prompt)
        return reason.strip()

recommender_llm = RecommenderLLM()
