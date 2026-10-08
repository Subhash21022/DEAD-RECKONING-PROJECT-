from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .websocket_manager import ConnectionManager
from .routes import simulation


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.ws_manager = ConnectionManager()

    db_available = False
    try:
        from .database import init_db, async_session
        await init_db()
        app.state.db_session = async_session
        db_available = True
    except Exception as e:
        print(f"\n{'=' * 70}")
        print(f"[DATABASE] PostgreSQL not available ({type(e).__name__}: {e})")
        print("[DATABASE] Running in SIMULATION-ONLY mode (in-memory).")
        print(f"{'=' * 70}\n")

    app.state.db_available = db_available
    yield

    if db_available:
        try:
            from .database import close_db
            await close_db()
        except Exception:
            pass


app = FastAPI(
    title="Forest Ranger Navigation API",
    description="DeadReckon AGY — Real-time Ranger Tracking, Anti-Poaching Intelligence & Patrol Analytics",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Simulation routes always available (in-memory, no DB needed)
app.include_router(simulation.router)

# Database-dependent routes — load only if imports succeed
try:
    from .routes import telemetry, sync, patrol, alerts, sightings, geofence
    from .auth import hash_password, create_access_token, verify_password
    from .schemas import RangerCreate, RangerOut, TokenRequest, TokenResponse
    from .models import Ranger
    from .database import get_db

    from sqlalchemy import select
    from sqlalchemy.ext.asyncio import AsyncSession
    from fastapi import Depends, HTTPException, status

    app.include_router(telemetry.router, prefix="/api/v1")
    app.include_router(sync.router, prefix="/api/v1")
    app.include_router(patrol.router, prefix="/api/v1")
    app.include_router(alerts.router, prefix="/api/v1")
    app.include_router(sightings.router, prefix="/api/v1")
    app.include_router(geofence.router, prefix="/api/v1")

    @app.post("/api/v1/auth/register", response_model=RangerOut, status_code=201)
    async def register_ranger(
        body: RangerCreate,
        db: AsyncSession = Depends(get_db),
    ):
        existing = await db.execute(
            select(Ranger).where(
                (Ranger.callsign == body.callsign) | (Ranger.badge_number == body.badge_number)
            )
        )
        if existing.scalar_one_or_none() is not None:
            raise HTTPException(status_code=409, detail="Callsign or badge number already registered")

        ranger = Ranger(
            name=body.name,
            callsign=body.callsign,
            badge_number=body.badge_number,
            password_hash=hash_password(body.password),
        )
        db.add(ranger)
        await db.flush()
        await db.refresh(ranger)
        return RangerOut.model_validate(ranger)

    @app.post("/api/v1/auth/token", response_model=TokenResponse)
    async def login(
        body: TokenRequest,
        db: AsyncSession = Depends(get_db),
    ):
        result = await db.execute(select(Ranger).where(Ranger.callsign == body.callsign))
        ranger = result.scalar_one_or_none()
        if ranger is None or not verify_password(body.password, ranger.password_hash):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

        token = create_access_token(data={"sub": str(ranger.id)})
        return TokenResponse(access_token=token)

    print("[ROUTES] Full PostGIS routes registered.")

except Exception as e:
    print(f"[ROUTES] PostGIS routes skipped ({type(e).__name__}: {e})")
    print("[ROUTES] Simulation routes are active at /api/v1/patrol/* and /ws/live")


@app.get("/")
async def root():
    return {
        "message": "Forest Ranger Navigation API is running",
        "docs": "/docs",
        "health": "/health",
        "db_connected": getattr(app.state, "db_available", False),
    }


@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "service": "forest-ranger-backend",
        "db_available": getattr(app.state, "db_available", False),
        "mode": "full" if getattr(app.state, "db_available", False) else "simulation",
        "websocket_connections": app.state.ws_manager.connection_count
            if hasattr(app.state, "ws_manager") else 0,
    }

