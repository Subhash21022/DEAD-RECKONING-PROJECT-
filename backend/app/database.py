from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.orm import DeclarativeBase
from sqlalchemy import text
from typing import AsyncGenerator

from .config import settings

engine = create_async_engine(
    settings.DATABASE_URL,
    echo=False,
    pool_size=20,
    max_overflow=10,
    pool_pre_ping=True,
)

async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
        finally:
            await session.close()


async def init_db() -> None:
    try:
        async with engine.begin() as conn:
            await conn.execute(text("CREATE EXTENSION IF NOT EXISTS postgis"))
            await conn.execute(text("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\""))
            await conn.run_sync(Base.metadata.create_all)
        print("[DATABASE] PostgreSQL + PostGIS initialized successfully.")
    except Exception as e:
        print("\n" + "=" * 70)
        print(f"[DATABASE NOTICE] Could not connect to PostgreSQL ({e}).")
        print("Backend is running in STANDALONE mode.")
        print("Start PostgreSQL on port 5432 to enable PostGIS table persistence.")
        print("=" * 70 + "\n")


async def close_db() -> None:
    try:
        await engine.dispose()
    except Exception:
        pass

