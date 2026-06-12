import chromadb
from typing import List
from sentence_transformers import SentenceTransformer
from app.models import FoodItem

class VectorStore:
    def __init__(self):
        # Initialize an in-memory ChromaDB client for demonstration
        self.chroma_client = chromadb.Client()
        # Create a collection
        self.collection = self.chroma_client.create_collection(name="food_menu")
        # Load a lightweight, CPU-friendly embedding model
        self.embedding_model = SentenceTransformer('all-MiniLM-L6-v2')
        self.is_initialized = False

    def initialize_db(self, food_items: List[FoodItem]):
        """Embeds and loads the menu into ChromaDB"""
        if self.is_initialized or not food_items:
            return
            
        docs = []
        metadatas = []
        ids = []
        embeddings = []
        
        for item in food_items:
            # Create a rich text representation for embedding
            text_to_embed = f"Name: {item.name}. Description: {item.description}. Ingredients: {', '.join(item.ingredients)}. Category: {item.category}."
            
            docs.append(text_to_embed)
            metadatas.append({
                "name": item.name,
                "category": item.category,
                "tags": ",".join(item.dietary_tags)
            })
            ids.append(item.id)
            
        # Generate embeddings using the sentence-transformer model
        vectors = self.embedding_model.encode(docs).tolist()
        
        # Add to ChromaDB
        self.collection.add(
            embeddings=vectors,
            documents=docs,
            metadatas=metadatas,
            ids=ids
        )
        self.is_initialized = True

    def search(self, query: str, safe_food_ids: List[str], top_k: int = 3) -> List[str]:
        """
        Searches the vector DB using the query, but restricts results ONLY to the 
        safe_food_ids (passed from the Rule-Based filtering layer).
        """
        if not safe_food_ids:
            return []
            
        # Embed the search query
        query_vector = self.embedding_model.encode([query]).tolist()
        
        # We use a `where` filter to only search among safe foods
        results = self.collection.query(
            query_embeddings=query_vector,
            n_results=top_k,
            where={"$and": [{"id": {"$in": safe_food_ids}}]} if False else None
            # ChromaDB's in-memory `where` filter on IDs has specific syntax.
            # For simplicity in this demo, we'll retrieve more and filter locally.
        )
        
        # Manual intersection to ensure absolute safety and correct ordering
        # Since Chroma in-memory might not fully support complex $in ID filters elegantly
        
        raw_results = self.collection.query(
            query_embeddings=query_vector,
            n_results=len(safe_food_ids) # Get all possible matches to rank them
        )
        
        ranked_safe_ids = []
        if raw_results and raw_results['ids']:
            for item_id in raw_results['ids'][0]:
                if item_id in safe_food_ids:
                    ranked_safe_ids.append(item_id)
                if len(ranked_safe_ids) == top_k:
                    break
                    
        return ranked_safe_ids

vector_store = VectorStore()
