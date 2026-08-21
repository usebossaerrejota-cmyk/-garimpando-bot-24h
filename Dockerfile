# syntax=docker/dockerfile:1.6

FROM mcr.microsoft.com/playwright/python:v1.48.0-noble

WORKDIR /app

RUN pip install --no-cache-dir \
    python-telegram-bot==21.6 \
    playwright==1.48.0 \
    beautifulsoup4==4.12.3 \
    httpx==0.27.2 \
    python-dotenv==1.0.1

RUN cat > /app/bot.py <<'PY'
import os
import re
import json
import asyncio
import sqlite3
from datetime import datetime
from urllib.parse import quote_plus

from bs4 import BeautifulSoup
from playwright.async_api import async_playwright
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CommandHandler,
    CallbackQueryHandler,
    ContextTypes,
)

TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
TARGET_CHAT_ID = os.getenv("TARGET_CHAT_ID", "").strip()

MIN_DISCOUNT = int(os.getenv("MIN_DISCOUNT", "0"))
MAX_RESULTS = int(os.getenv("MAX_RESULTS", "5"))

AUTO_INTERVAL_MINUTES = max(
    5, int(os.getenv("AUTO_INTERVAL_MINUTES", "15"))
)

AUTO_QUERIES = [
    x.strip()
    for x in os.getenv(
        "AUTO_QUERIES",
        "beleza,perfume,shampoo,air fryer,casa,academia,suplemento"
    ).split(",")
    if x.strip()
]

STATE = {
    "auto": True,
    "last_run": None,
    "last_error": None,
    "cycles": 0,
    "posts": 0,
}

DB_PATH = "/app/garimpando.db"


def db_connect():
    return sqlite3.connect(DB_PATH)


def db_init():
    with db_connect() as con:
        con.execute(
            """
            CREATE TABLE IF NOT EXISTS seen (
                url TEXT PRIMARY KEY,
                title TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )


def db_has(url):
    with db_connect() as con:
        row = con.execute(
            "SELECT 1 FROM seen WHERE url=?",
            (url,)
        ).fetchone()
        return row is not None


def db_add(url, title):
    with db_connect() as con:
        con.execute(
            "INSERT OR IGNORE INTO seen(url,title) VALUES (?,?)",
            (url, title)
        )


def db_clear():
    with db_connect() as con:
        con.execute("DELETE FROM seen")


def menu():
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton(
                "🔎 Buscar oferta",
                callback_data="help_search"
            ),
            InlineKeyboardButton(
                "📊 Status",
                callback_data="status"
            ),
        ],
        [
            InlineKeyboardButton(
                "▶️ Automático",
                callback_data="auto_on"
            ),
            InlineKeyboardButton(
                "⏸️ Pausar",
                callback_data="auto_off"
            ),
        ],
    ])


def brl(value):
    if value is None:
        return "Consulte o preço"

    text = f"{value:,.2f}"
    text = text.replace(",", "X").replace(".", ",").replace("X", ".")
    return f"R$ {text}"


def parse_money(text):
    if not text:
        return None

    m = re.search(
        r"R\$\s*([\d\.]+)(?:,(\d{1,2}))?",
        text
    )

    if not m:
        return None

    inteiro = m.group(1).replace(".", "")
    decimal = m.group(2) or "00"

    try:
        return float(f"{inteiro}.{decimal}")
    except Exception:
        return None


def clean_url(url):
    if not url:
        return ""

    url = url.split("#")[0]

    if "mercadolivre.com.br" not in url:
        return ""

    if "/p/" in url:
        return url

    if "/MLB-" in url or "MLB-" in url:
        return url

    return url


async def scrape_mercado_livre(query, limit=20):
    slug = quote_plus(query).replace("+", "-")
    url = f"https://lista.mercadolivre.com.br/{slug}"

    products = []

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-blink-features=AutomationControlled",
            ],
        )

        context = await browser.new_context(
            locale="pt-BR",
            viewport={"width": 1365, "height": 900},
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/131.0.0.0 Safari/537.36"
            ),
        )

        page = await context.new_page()

        try:
            await page.goto(
                url,
                wait_until="domcontentloaded",
                timeout=60000,
            )

            await page.wait_for_timeout(4000)

            try:
                await page.mouse.wheel(0, 1600)
                await page.wait_for_timeout(1200)
            except Exception:
                pass

            html = await page.content()

        finally:
            await browser.close()

    soup = BeautifulSoup(html, "html.parser")

    selectors = [
        "li.ui-search-layout__item",
        "div.ui-search-result__wrapper",
        "[class*='ui-search-layout__item']",
        "[class*='poly-card']",
        "[class*='ui-search-result']",
    ]

    cards = []

    for selector in selectors:
        found = soup.select(selector)

        if len(found) >= 3:
            cards = found
            break

    seen_urls = set()

    for card in cards:
        anchors = card.find_all("a", href=True)

        href = ""
        title = ""

        for a in anchors:
            candidate = clean_url(a.get("href", ""))

            if not candidate:
                continue

            href = candidate

            title_node = (
                a.select_one(
                    ".poly-component__title"
                )
                or a.select_one(
                    ".ui-search-item__title"
                )
                or a.select_one("h2")
            )

            if title_node:
                title = title_node.get_text(
                    " ",
                    strip=True
                )

            if not title:
                title = a.get_text(
                    " ",
                    strip=True
                )

            if href:
                break

        if not href or href in seen_urls:
            continue

        if not title or len(title) < 5:
            title_node = (
                card.select_one(".poly-component__title")
                or card.select_one(".ui-search-item__title")
                or card.select_one("h2")
                or card.select_one("h3")
            )

            if title_node:
                title = title_node.get_text(
                    " ",
                    strip=True
                )

        if not title or len(title) < 5:
            continue

        text = card.get_text(
            " ",
            strip=True
        )

        prices = []

        for money_el in card.select(
            ".andes-money-amount, "
            "[class*='money-amount']"
        ):
            value = parse_money(
                money_el.get_text(
                    " ",
                    strip=True
                )
            )

            if value and value not in prices:
                prices.append(value)

        if not prices:
            for raw in re.findall(
                r"R\$\s*[\d\.]+(?:,\d{1,2})?",
                text
            ):
                value = parse_money(raw)

                if value and value not in prices:
                    prices.append(value)

        price = None
        old_price = None

        if prices:
            price = prices[-1]

            if len(prices) >= 2:
                possible_old = prices[0]

                if possible_old > price:
                    old_price = possible_old

        discount = None

        dm = re.search(
            r"(\d{1,2})\s*%\s*(?:OFF|off|desconto)?",
            text
        )

        if dm:
            try:
                discount = int(dm.group(1))
            except Exception:
                pass

        if (
            discount is None
            and price
            and old_price
            and old_price > price
        ):
            discount = round(
                (1 - price / old_price) * 100
            )

        image = ""

        img = card.find("img")

        if img:
            image = (
                img.get("data-src")
                or img.get("data-lazy")
                or img.get("src")
                or ""
            )

        shipping = ""

        if "frete grátis" in text.lower():
            shipping = "Frete grátis"

        products.append({
            "title": title[:180],
            "url": href,
            "image": image,
            "price": price,
            "old_price": old_price,
            "discount": discount,
            "shipping": shipping,
        })

        seen_urls.add(href)

        if len(products) >= limit:
            break

    if products:
        return products

    # Fallback: tenta encontrar produtos estruturados dentro da página
    for script in soup.find_all(
        "script",
        type="application/ld+json"
    ):
        raw = script.string

        if not raw:
            continue

        try:
            data = json.loads(raw)
        except Exception:
            continue

        blocks = (
            data
            if isinstance(data, list)
            else [data]
        )

        for block in blocks:
            if not isinstance(block, dict):
                continue

            items = block.get("itemListElement", [])

            for item in items:
                if not isinstance(item, dict):
                    continue

                obj = item.get("item", item)

                if not isinstance(obj, dict):
                    continue

                href = clean_url(
                    obj.get("url", "")
                )

                title = (
                    obj.get("name")
                    or obj.get("title")
                    or ""
                )

                if not href or not title:
                    continue

                products.append({
                    "title": title[:180],
                    "url": href,
                    "image": obj.get("image", ""),
                    "price": None,
                    "old_price": None,
                    "discount": None,
                    "shipping": "",
                })

                if len(products) >= limit:
                    return products

    return products


def make_caption(p):
    lines = [
        "🔥 OFERTA NO MERCADO LIVRE",
        "",
        p["title"],
        "",
    ]

    if (
        p["old_price"]
        and p["price"]
        and p["old_price"] > p["price"]
    ):
        lines.append(
            f"De {brl(p['old_price'])}"
        )
        lines.append(
            f"Por *{brl(p['price'])}*"
        )
    elif p["price"]:
        lines.append(
            f"Por *{brl(p['price'])}*"
        )

    if p["discount"]:
        lines.append(
            f"💸 {p['discount']}% OFF"
        )

    if p["shipping"]:
        lines.append(
            f"🚚 {p['shipping']}"
        )

    lines.extend([
        "",
        f"🛍️ Comprar: {p['url']}",
        "",
        "Preço e disponibilidade podem mudar a qualquer momento.",
    ])

    return "\n".join(lines)


async def send_product(bot, chat_id, p):
    caption = make_caption(p)

    if p.get("image"):
        try:
            await bot.send_photo(
                chat_id=chat_id,
                photo=p["image"],
                caption=caption,
                parse_mode=ParseMode.MARKDOWN,
            )

            db_add(
                p["url"],
                p["title"]
            )

            STATE["posts"] += 1
            return

        except Exception:
            pass

    await bot.send_message(
        chat_id=chat_id,
        text=caption,
        parse_mode=ParseMode.MARKDOWN,
        disable_web_page_preview=False,
    )

    db_add(
        p["url"],
        p["title"]
    )

    STATE["posts"] += 1


async def choose_products(
    query,
    quantity=5,
    ignore_history=False
):
    products = await scrape_mercado_livre(
        query,
        limit=max(20, quantity * 5)
    )

    chosen = []

    for p in products:
        if (
            not ignore_history
            and db_has(p["url"])
        ):
            continue

        discount = p.get("discount")

        if (
            discount is not None
            and discount < MIN_DISCOUNT
        ):
            continue

        # Produto sem desconto explícito ainda pode entrar
        # quando o filtro está em zero.
        if (
            discount is None
            and MIN_DISCOUNT > 0
        ):
            continue

        chosen.append(p)

    chosen.sort(
        key=lambda x: (
            x.get("discount") or 0,
            bool(x.get("shipping")),
        ),
        reverse=True,
    )

    return chosen[:quantity]


async def start(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    text = (
        "Garimpando Bot 24H ativo.\n\n"
        "Você controla tudo por aqui e o servidor "
        "continua trabalhando sozinho.\n\n"
        "Comandos:\n"
        "/buscar air fryer — busca agora\n"
        "/status — situação do robô\n"
        "/iniciar — liga o modo automático\n"
        "/pausar — pausa o modo automático\n"
        "/limpar — zera produtos já enviados"
    )

    await update.message.reply_text(
        text,
        reply_markup=menu()
    )


async def status(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    last = (
        STATE["last_run"]
        or "ainda não executou"
    )

    err = (
        STATE["last_error"]
        or "nenhum"
    )

    text = (
        f"Modo automático: "
        f"{'LIGADO' if STATE['auto'] else 'PAUSADO'}\n"
        f"Intervalo: {AUTO_INTERVAL_MINUTES} min\n"
        f"Posts por ciclo: 1\n"
        f"Desconto mínimo: {MIN_DISCOUNT}%\n"
        f"Buscas: {', '.join(AUTO_QUERIES)}\n"
        f"Última execução: {last}\n"
        f"Ciclos: {STATE['cycles']} | "
        f"Posts: {STATE['posts']}\n"
        f"Último erro: {err}\n"
        f"Afiliado: passthrough"
    )

    if update.callback_query:
        await update.callback_query.answer()

        await update.callback_query.message.reply_text(
            text,
            reply_markup=menu()
        )
    else:
        await update.message.reply_text(
            text,
            reply_markup=menu()
        )


async def buscar(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    query = " ".join(
        context.args
    ).strip()

    if not query:
        await update.message.reply_text(
            "Use, por exemplo:\n"
            "/buscar perfume"
        )
        return

    await update.message.reply_text(
        f"Buscando ofertas de: {query}"
    )

    try:
        selected = await choose_products(
            query,
            quantity=MAX_RESULTS,
            ignore_history=True,
        )

        if not selected:
            await update.message.reply_text(
                "Não encontrei produtos nessa busca agora. "
                "Vou tentar novamente no próximo ciclo."
            )
            return

        for p in selected:
            await send_product(
                context.bot,
                update.effective_chat.id,
                p
            )

        STATE["last_error"] = None

    except Exception as e:
        STATE["last_error"] = (
            f"{type(e).__name__}: {str(e)[:120]}"
        )

        await update.message.reply_text(
            f"Erro na busca: {type(e).__name__}"
        )


async def limpar(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    db_clear()

    await update.message.reply_text(
        "Histórico de produtos limpo."
    )


async def iniciar(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    STATE["auto"] = True

    await update.message.reply_text(
        "Modo automático ligado.",
        reply_markup=menu()
    )


async def pausar(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    STATE["auto"] = False

    await update.message.reply_text(
        "Modo automático pausado.",
        reply_markup=menu()
    )


async def auto_cycle(app):
    if not TARGET_CHAT_ID:
        STATE["last_error"] = (
            "TARGET_CHAT_ID não configurado"
        )
        return

    for query in AUTO_QUERIES:
        try:
            picks = await choose_products(
                query,
                quantity=1,
                ignore_history=False,
            )

            if picks:
                await send_product(
                    app.bot,
                    TARGET_CHAT_ID,
                    picks[0]
                )

                STATE["last_error"] = None
                break

        except Exception as e:
            STATE["last_error"] = (
                f"{query}: "
                f"{type(e).__name__}: "
                f"{str(e)[:100]}"
            )

    STATE["cycles"] += 1

    STATE["last_run"] = datetime.now().strftime(
        "%d/%m/%Y %H:%M"
    )


async def auto_worker(app):
    await asyncio.sleep(12)

    while True:
        try:
            if STATE["auto"]:
                await auto_cycle(app)

        except Exception as e:
            STATE["last_error"] = (
                f"{type(e).__name__}: "
                f"{str(e)[:120]}"
            )

        await asyncio.sleep(
            AUTO_INTERVAL_MINUTES * 60
        )


async def post_init(app):
    asyncio.create_task(
        auto_worker(app)
    )


async def buttons(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    q = update.callback_query

    await q.answer()

    if q.data == "auto_on":
        STATE["auto"] = True

        await q.message.reply_text(
            "Modo automático ligado.",
            reply_markup=menu()
        )

    elif q.data == "auto_off":
        STATE["auto"] = False

        await q.message.reply_text(
            "Modo automático pausado.",
            reply_markup=menu()
        )

    elif q.data == "status":
        last = (
            STATE["last_run"]
            or "ainda não executou"
        )

        err = (
            STATE["last_error"]
            or "nenhum"
        )

        await q.message.reply_text(
            f"Modo automático: "
            f"{'LIGADO' if STATE['auto'] else 'PAUSADO'}\n"
            f"Intervalo: {AUTO_INTERVAL_MINUTES} min\n"
            f"Desconto mínimo: {MIN_DISCOUNT}%\n"
            f"Última execução: {last}\n"
            f"Ciclos: {STATE['cycles']} | "
            f"Posts: {STATE['posts']}\n"
            f"Último erro: {err}",
            reply_markup=menu()
        )

    elif q.data == "help_search":
        await q.message.reply_text(
            "Digite, por exemplo:\n"
            "/buscar perfume importado"
        )


def main():
    if not TOKEN:
        raise RuntimeError(
            "TELEGRAM_BOT_TOKEN não configurado"
        )

    db_init()

    app = (
        Application.builder()
        .token(TOKEN)
        .post_init(post_init)
        .build()
    )

    app.add_handler(
        CommandHandler("start", start)
    )

    app.add_handler(
        CommandHandler("buscar", buscar)
    )

    app.add_handler(
        CommandHandler("status", status)
    )

    app.add_handler(
        CommandHandler("limpar", limpar)
    )

    app.add_handler(
        CommandHandler("iniciar", iniciar)
    )

    app.add_handler(
        CommandHandler("pausar", pausar)
    )

    app.add_handler(
        CallbackQueryHandler(buttons)
    )

    app.run_polling(
        allowed_updates=Update.ALL_TYPES,
        drop_pending_updates=True,
    )


if __name__ == "__main__":
    main()
PY

ENV PYTHONUNBUFFERED=1

CMD ["python", "/app/bot.py"]
