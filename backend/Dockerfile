FROM python:3.11-slim
WORKDIR /app

# Copy requirements from the build context (backend/requirements.txt)
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the backend source into the image
COPY . /app

CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]