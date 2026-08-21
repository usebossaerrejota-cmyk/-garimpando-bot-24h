# syntax=docker/dockerfile:1.6

FROM mcr.microsoft.com/playwright/python:v1.48.0-noble

WORKDIR /app

RUN pip install --no-cache-dir \
    python-telegram-bot==21.6 \
    playwright==1.48.0 \
    beautifulsoup4==4.12.3 \
    httpx==0.27.2

RUN cat > /app/bot.py <<'PY'
import os
import re
import json
import asyncio
import sqlite3
from datetime import datetime
from urllib.parse import quote_plus, unquote, urlparse, parse_qs

from bs4 import BeautifulSoup
from playwright.async_api import async_playwright
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application,
    CommandHandler,
    CallbackQueryHandler,
    ContextTypes,
)

TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
TARGET_CHAT_ID = os.getenv("TARGET_CHAT_ID", "").strip()

MIN_DISCOUNT = int(os.getenv("MIN_DISCOUNT", "0"))
MAX_RESULTS = max(1, int(os.getenv("MAX_RESULTS", "5")))
AUTO_INTERVAL_MINUTES = max(
    5,
    int(os.getenv("AUTO_INTERVAL_MINUTES", "15"))
)

AUTO_QUERIES = [
    x.strip()
    for x in os.getenv(
        "AUTO_QUERIES",
        "beleza,perfume,shampoo,air fryer,casa,academia,suplemento"
    ).split(",")
    if x.strip()
]

DB_PATH = "/app/garimpando.db"

STATE = {
    "auto": True,
    "last_run": None,
    "last_error": None,
    "cycles": 0,
    "posts": 0,
}

DIAG = {
    "source": "nenhuma",
    "urls_found": 0,
    "products": 0,
    "last_query": "",
    "last_title": "",
}

PRODUCT_URL_RE = re.compile(r"(MLB-?\d{6,}|/p/MLB\d+|/up/MLB\d+)", re.I)

def log(msg):
    print(f"[garimpando] {msg}", flush=True)


def db():
    return sqlite3.connect(DB_PATH)


def init_db():
    with db() as con:
        con.execute("""
            CREATE TABLE IF NOT EXISTS seen (
                url TEXT PRIMARY KEY,
                title TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)


def already_seen(url):
    with db() as con:
        return con.execute(
            "SELECT 1 FROM seen WHERE url=?",
            (url,)
        ).fetchone() is not None


def remember(url, title):
    with db() as con:
        con.execute(
            "INSERT OR IGNORE INTO seen(url,title) VALUES (?,?)",
            (url, title)
        )


def clear_seen():
    with db() as con:
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
            )
        ],
        [
            InlineKeyboardButton(
                "▶️ Automático",
                callback_data="auto_on"
            ),
            InlineKeyboardButton(
                "⏸️ Pausar",
                callback_data="auto_off"
            )
        ]
    ])


def money(value):
    if value is None:
        return None

    try:
        value = float(value)
    except Exception:
        return None

    txt = f"{value:,.2f}"
    txt = txt.replace(",", "X").replace(".", ",").replace("X", ".")
    return f"R$ {txt}"


def clean_ml_url(url):
    if not url:
        return ""

    url = unquote(url)

    if "uddg=" in url:
        try:
            qs = parse_qs(urlparse(url).query)
            if "uddg" in qs:
                url = qs["uddg"][0]
        except Exception:
            pass

    if "mercadolivre.com.br" not in url.lower():
        return ""

    url = url.split("#")[0]

    bad = [
        "/ajuda/",
        "/institucional/",
        "/ofertas/",
        "/categorias/",
        "/lista/",
    ]

    if any(x in url.lower() for x in bad):
        return ""

    if not PRODUCT_URL_RE.search(url):
        return ""

    return url


def first_number(text):
    if text is None:
        return None

    text = str(text).strip()

    try:
        return float(text)
    except Exception:
        pass

    m = re.search(
        r"([\d\.]+)(?:,(\d{1,2}))?",
        text
    )

    if not m:
        return None

    integer = m.group(1).replace(".", "")
    decimal = m.group(2) or "00"

    try:
        return float(f"{integer}.{decimal}")
    except Exception:
        return None


def parse_ml_fraction_price(text):
    if not text:
        return None

    digits = re.sub(r"[^\d]", "", str(text))

    if not digits:
        return None

    try:
        return float(digits)
    except Exception:
        return None


async def new_browser(p):
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
        viewport={
            "width": 1365,
            "height": 900
        },
        user_agent=(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/131.0.0.0 Safari/537.36"
        ),
    )

    return browser, context


async def direct_ml_urls(context, query, limit=20):
    slug = quote_plus(query).replace("+", "-")

    candidates = [
        f"https://lista.mercadolivre.com.br/{slug}",
        f"https://www.mercadolivre.com.br/ofertas?search={quote_plus(query)}",
    ]

    urls = []

    for search_url in candidates:
        page = await context.new_page()

        try:
            response = await page.goto(
                search_url,
                wait_until="domcontentloaded",
                timeout=45000,
            )

            await page.wait_for_timeout(3500)

            DIAG["last_title"] = (
                await page.title()
            )[:120]

            hrefs = await page.locator("a").evaluate_all(
                "(els) => els.map(a => a.href)"
            )

            log(
                f"direct_ml_urls: url={search_url} final_url={page.url} "
                f"title={DIAG['last_title']!r} total_hrefs={len(hrefs)}"
            )

            for href in hrefs:
                good = clean_ml_url(href)

                if good and good not in urls:
                    urls.append(good)

                if len(urls) >= limit:
                    break

        except Exception as e:
            STATE["last_error"] = (
                f"ML direto: {type(e).__name__}"
            )

        finally:
            await page.close()

        if urls:
            DIAG["source"] = "Mercado Livre direto"
            break

    return urls[:limit]


async def direct_ml_offers(context, query, limit=25):
    slug = quote_plus(query).replace("+", "-")

    candidates = [
        f"https://lista.mercadolivre.com.br/{slug}",
        f"https://www.mercadolivre.com.br/ofertas?search={quote_plus(query)}",
    ]

    offers = []

    for search_url in candidates:
        page = await context.new_page()

        try:
            await page.goto(
                search_url,
                wait_until="domcontentloaded",
                timeout=45000,
            )

            await page.wait_for_timeout(3500)

            DIAG["last_title"] = (
                await page.title()
            )[:120]

            raw_cards = await page.evaluate(
                """
                () => {
                    const cards = document.querySelectorAll(
                        'li.ui-search-layout__item, div.ui-search-result__wrapper, ' +
                        '.poly-card'
                    );
                    const out = [];
                    for (const card of cards) {
                        const linkEl = card.querySelector(
                            'a.poly-component__title, a.ui-search-link, ' +
                            'a.ui-search-item__group__element, ' +
                            'a[href*="mercadolivre.com.br"]'
                        );
                        if (!linkEl) continue;
                        const titleEl = card.querySelector(
                            '.poly-component__title, .ui-search-item__title'
                        ) || linkEl;
                        const curFrac = card.querySelector(
                            '.poly-price__current .andes-money-amount__fraction, ' +
                            '[class*="current"] .andes-money-amount__fraction'
                        );
                        const anyFrac = card.querySelector(
                            '.andes-money-amount__fraction'
                        );
                        const priceEl = curFrac || anyFrac;
                        const oldFrac = card.querySelector(
                            's.andes-money-amount--previous .andes-money-amount__fraction, ' +
                            '[class*="previous"] .andes-money-amount__fraction'
                        );
                        const discountEl = card.querySelector('.polylabel-pill');
                        const imgEl = card.querySelector('img');
                        out.push({
                            href: linkEl.href || '',
                            title: (titleEl.textContent || '').trim(),
                            price: priceEl ? priceEl.textContent.trim() : null,
                            oldPriceText: oldFrac ? oldFrac.textContent.trim() : null,
                            discountText: discountEl ? discountEl.textContent.trim() : null,
                            img: imgEl
                                ? (imgEl.src || imgEl.getAttribute('data-src') || '')
                                : '',
                        });
                    }
                    return out;
                }
                """
            )

            log(
                f"direct_ml_offers: url={search_url} final_url={page.url} "
                f"title={DIAG['last_title']!r} cards={len(raw_cards)}"
            )

            for c in raw_cards:
                clean_url = clean_ml_url(c.get("href") or "")

                if not clean_url:
                    continue

                if any(o["url"] == clean_url for o in offers):
                    continue

                title = (c.get("title") or "").strip()

                if not title:
                    continue

                price = parse_ml_fraction_price(c.get("price"))

                if price is None:
                    continue

                old_price = parse_ml_fraction_price(
                    c.get("oldPriceText")
                )

                discount = None
                dtext = c.get("discountText") or ""
                dm = re.search(r"(\d+)\s*%", dtext)

                if dm:
                    discount = int(dm.group(1))

                offers.append({
                    "url": clean_url,
                    "title": title,
                    "price": price,
                    "old_price": old_price,
                    "discount": discount,
                    "image": c.get("img") or "",
                    "shipping": "",
                })

                if len(offers) >= limit:
                    break

        except Exception as e:
            STATE["last_error"] = (
                f"ML ofertas direto: {type(e).__name__}"
            )

            log(
                f"direct_ml_offers: ERROR em {search_url}: "
                f"{type(e).__name__}: {e}"
            )

        finally:
            await page.close()

        if offers:
            DIAG["source"] = "Mercado Livre direto (listagem)"
            break

    return offers[:limit]


async def bing_urls(context, query, limit=20):
    q = quote_plus(
        f'site:mercadolivre.com.br "{query}"'
    )

    url = f"https://www.bing.com/search?q={q}"

    page = await context.new_page()
    urls = []

    try:
        await page.goto(
            url,
            wait_until="domcontentloaded",
            timeout=45000,
        )

        await page.wait_for_timeout(2500)

        hrefs = await page.locator("a").evaluate_all(
            "(els) => els.map(a => a.href)"
        )

        for href in hrefs:
            good = clean_ml_url(href)

            if good and good not in urls:
                urls.append(good)

            if len(urls) >= limit:
                break

    except Exception as e:
        STATE["last_error"] = (
            f"Bing: {type(e).__name__}"
        )

    finally:
        await page.close()

    if urls:
        DIAG["source"] = "Bing"

    return urls[:limit]


async def duck_urls(context, query, limit=20):
    q = quote_plus(
        f'site:mercadolivre.com.br "{query}"'
    )

    url = f"https://html.duckduckgo.com/html/?q={q}"

    page = await context.new_page()
    urls = []

    try:
        await page.goto(
            url,
            wait_until="domcontentloaded",
            timeout=45000,
        )

        await page.wait_for_timeout(2500)

        hrefs = await page.locator("a").evaluate_all(
            "(els) => els.map(a => a.href)"
        )

        for href in hrefs:
            good = clean_ml_url(href)

            if good and good not in urls:
                urls.append(good)

            if len(urls) >= limit:
                break

    except Exception as e:
        STATE["last_error"] = (
            f"DuckDuckGo: {type(e).__name__}"
        )

    finally:
        await page.close()

    if urls:
        DIAG["source"] = "DuckDuckGo"

    return urls[:limit]


def parse_json_ld(soup):
    title = ""
    image = ""
    price = None

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

        objects = (
            data
            if isinstance(data, list)
            else [data]
        )

        for obj in objects:
            if not isinstance(obj, dict):
                continue

            graph = obj.get("@graph")

            if isinstance(graph, list):
                objects.extend(
                    x for x in graph
                    if isinstance(x, dict)
                )

            obj_type = str(
                obj.get("@type", "")
            ).lower()

            if (
                "product" not in obj_type
                and "individualproduct" not in obj_type
            ):
                continue

            title = (
                obj.get("name")
                or title
            )

            raw_image = obj.get("image")

            if isinstance(raw_image, str):
                image = raw_image

            elif isinstance(raw_image, list):
                if raw_image:
                    if isinstance(raw_image[0], str):
                        image = raw_image[0]

                    elif isinstance(raw_image[0], dict):
                        image = (
                            raw_image[0].get("url")
                            or ""
                        )

            offers = obj.get("offers")

            if isinstance(offers, list):
                offers = (
                    offers[0]
                    if offers
                    else None
                )

            if isinstance(offers, dict):
                price = first_number(
                    offers.get("price")
                    or offers.get("lowPrice")
                )

            if title:
                return title, image, price

    return title, image, price


async def product_details(context, url):
    page = await context.new_page()

    try:
        await page.goto(
            url,
            wait_until="domcontentloaded",
            timeout=45000,
        )

        await page.wait_for_timeout(2200)

        html = await page.content()
        final_url = page.url

        soup = BeautifulSoup(
            html,
            "html.parser"
        )

        title = ""
        image = ""
        price = None
        old_price = None

        og_title = soup.select_one(
            'meta[property="og:title"]'
        )

        if og_title:
            title = (
                og_title.get("content")
                or ""
            ).strip()

        og_image = soup.select_one(
            'meta[property="og:image"]'
        )

        if og_image:
            image = (
                og_image.get("content")
                or ""
            ).strip()

        price_meta = (
            soup.select_one(
                'meta[property="product:price:amount"]'
            )
            or soup.select_one(
                'meta[itemprop="price"]'
            )
        )

        if price_meta:
            price = first_number(
                price_meta.get("content")
                or price_meta.get("value")
            )

        j_title, j_image, j_price = parse_json_ld(
            soup
        )

        title = title or j_title
        image = image or j_image
        price = price or j_price

        if not title:
            h1 = soup.find("h1")

            if h1:
                title = h1.get_text(
                    " ",
                    strip=True
                )

        body_text = soup.get_text(
            " ",
            strip=True
        )

        if price is None:
            m = re.search(
                r"R\$\s*([\d\.]+)(?:,(\d{1,2}))?",
                body_text
            )

            if m:
                integer = m.group(1).replace(".", "")
                decimal = m.group(2) or "00"

                price = first_number(
                    f"{integer}.{decimal}"
                )

        generic_titles = {"mercado libre", "mercado livre", ""}

        if (title or "").strip().lower() in generic_titles:
            log(
                f"product_details: possivel bloqueio/pagina generica em {url} "
                f"-> final_url={final_url} title={title!r}"
            )
            return None

        if not title or price is None:
            log(
                f"product_details: sem titulo/preco em {url} -> "
                f"final_url={final_url} title={title!r} price={price}"
            )
            return None

        discount = None

        dm = re.search(
            r"(\d{1,2})\s*%\s*OFF",
            body_text,
            re.I
        )

        if dm:
            try:
                discount = int(
                    dm.group(1)
                )
            except Exception:
                pass

        shipping = ""

        if "frete grátis" in body_text.lower():
            shipping = "Frete grátis"

        log(
            f"product_details: OK title={title[:60]!r} price={price} "
            f"url={final_url}"
        )

        return {
            "title": title[:180],
            "url": final_url,
            "image": image,
            "price": price,
            "old_price": old_price,
            "discount": discount,
            "shipping": shipping,
        }

    except Exception as e:
        STATE["last_error"] = (
            f"Produto: {type(e).__name__}"
        )

        log(f"product_details: ERROR em {url}: {type(e).__name__}: {e}")

        return None

    finally:
        await page.close()


async def search_products(query, limit=10):
    DIAG["last_query"] = query
    DIAG["source"] = "nenhuma"
    DIAG["urls_found"] = 0
    DIAG["products"] = 0
    DIAG["last_title"] = ""

    log(f"search_products: iniciando busca por {query!r}")

    async with async_playwright() as p:
        browser, context = await new_browser(p)

        try:
            offers = await direct_ml_offers(
                context,
                query,
                limit=25
            )

            if offers:
                DIAG["urls_found"] = len(offers)

                log(
                    f"search_products: {len(offers)} ofertas extraidas "
                    f"direto da listagem"
                )

                products = offers[:limit]

                DIAG["products"] = len(products)

                return products

            log(
                "search_products: listagem direta nao trouxe ofertas, "
                "tentando fallback por pagina de produto"
            )

            urls = await direct_ml_urls(
                context,
                query,
                limit=25
            )

            if not urls:
                urls = await bing_urls(
                    context,
                    query,
                    limit=25
                )

            if not urls:
                urls = await duck_urls(
                    context,
                    query,
                    limit=25
                )

            DIAG["urls_found"] = len(urls)

            log(f"search_products: {len(urls)} URLs candidatas encontradas")

            products = []

            for url in urls[:12]:
                item = await product_details(
                    context,
                    url
                )

                if not item:
                    continue

                if item["url"] in [
                    x["url"]
                    for x in products
                ]:
                    continue

                products.append(item)

                if len(products) >= limit:
                    break

            DIAG["products"] = len(products)

            return products

        finally:
            await browser.close()


def caption(p):
    lines = [
        "🔥 OFERTA NO MERCADO LIVRE",
        "",
        p["title"],
        "",
    ]

    if p.get("price") is not None:
        lines.append(
            f"Por {money(p['price'])}"
        )

    if p.get("discount"):
        lines.append(
            f"💸 {p['discount']}% OFF"
        )

    if p.get("shipping"):
        lines.append(
            f"🚚 {p['shipping']}"
        )

    lines.extend([
        "",
        f"🛍️ Comprar: {p['url']}",
        "",
        "Preço e disponibilidade podem mudar."
    ])

    return "\n".join(lines)


async def send_product(
    bot,
    chat_id,
    product
):
    text = caption(product)

    image = product.get("image")

    if image:
        try:
            await bot.send_photo(
                chat_id=chat_id,
                photo=image,
                caption=text,
            )

            remember(
                product["url"],
                product["title"]
            )

            STATE["posts"] += 1
            return

        except Exception:
            pass

    await bot.send_message(
        chat_id=chat_id,
        text=text,
        disable_web_page_preview=False,
    )

    remember(
        product["url"],
        product["title"]
    )

    STATE["posts"] += 1


async def choose_products(
    query,
    quantity=5,
    ignore_history=False
):
    products = await search_products(
        query,
        limit=max(
            quantity * 3,
            8
        )
    )

    selected = []

    for p in products:
        if (
            not ignore_history
            and already_seen(p["url"])
        ):
            continue

        discount = p.get("discount")

        if (
            MIN_DISCOUNT > 0
            and (
                discount is None
                or discount < MIN_DISCOUNT
            )
        ):
            continue

        selected.append(p)

    selected.sort(
        key=lambda x: (
            x.get("discount") or 0,
            bool(x.get("shipping"))
        ),
        reverse=True
    )

    return selected[:quantity]


async def start(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    await update.message.reply_text(
        "Garimpando Bot 24H ativo.\n\n"
        "Comandos:\n"
        "/buscar perfume\n"
        "/status\n"
        "/diagnostico\n"
        "/iniciar\n"
        "/pausar\n"
        "/limpar",
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
            "Use: /buscar perfume"
        )
        return

    await update.message.reply_text(
        f"Buscando ofertas de: {query}"
    )

    try:
        selected = await choose_products(
            query,
            quantity=MAX_RESULTS,
            ignore_history=True
        )

        if not selected:
            await update.message.reply_text(
                "Não encontrei produtos agora.\n"
                "Use /diagnostico para ver "
                "por onde a busca tentou passar."
            )
            return

        for product in selected:
            await send_product(
                context.bot,
                update.effective_chat.id,
                product
            )

        STATE["last_error"] = None

    except Exception as e:
        STATE["last_error"] = (
            f"{type(e).__name__}: "
            f"{str(e)[:120]}"
        )

        await update.message.reply_text(
            f"Erro: {type(e).__name__}"
        )


async def diagnostico(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    await update.message.reply_text(
        "Diagnóstico da busca\n\n"
        f"Última busca: {DIAG['last_query'] or 'nenhuma'}\n"
        f"Fonte usada: {DIAG['source']}\n"
        f"Links encontrados: {DIAG['urls_found']}\n"
        f"Produtos válidos: {DIAG['products']}\n"
        f"Título recebido: {DIAG['last_title'] or 'não informado'}\n"
        f"Último erro: {STATE['last_error'] or 'nenhum'}"
    )


async def status(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    text = (
        f"Modo automático: "
        f"{'LIGADO' if STATE['auto'] else 'PAUSADO'}\n"
        f"Intervalo: {AUTO_INTERVAL_MINUTES} min\n"
        f"Desconto mínimo: {MIN_DISCOUNT}%\n"
        f"Ciclos: {STATE['cycles']}\n"
        f"Posts: {STATE['posts']}\n"
        f"Última execução: "
        f"{STATE['last_run'] or 'ainda não executou'}\n"
        f"Último erro: "
        f"{STATE['last_error'] or 'nenhum'}"
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


async def limpar(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    clear_seen()

    await update.message.reply_text(
        "Histórico limpo."
    )


async def iniciar(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    STATE["auto"] = True

    await update.message.reply_text(
        "Modo automático ligado."
    )


async def pausar(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):
    STATE["auto"] = False

    await update.message.reply_text(
        "Modo automático pausado."
    )


async def auto_cycle(app):
    if not TARGET_CHAT_ID:
        STATE["last_error"] = (
            "TARGET_CHAT_ID não configurado"
        )
        return

    for query in AUTO_QUERIES:
        try:
            products = await choose_products(
                query,
                quantity=1,
                ignore_history=False
            )

            if products:
                await send_product(
                    app.bot,
                    TARGET_CHAT_ID,
                    products[0]
                )

                STATE["last_error"] = None
                break

        except Exception as e:
            STATE["last_error"] = (
                f"{query}: "
                f"{type(e).__name__}"
            )

    STATE["cycles"] += 1

    STATE["last_run"] = datetime.now().strftime(
        "%d/%m/%Y %H:%M"
    )


async def auto_worker(app):
    await asyncio.sleep(30)

    while True:
        if STATE["auto"]:
            try:
                await auto_cycle(app)
            except Exception as e:
                STATE["last_error"] = (
                    f"{type(e).__name__}: "
                    f"{str(e)[:100]}"
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

    if q.data == "help_search":
        await q.message.reply_text(
            "Digite: /buscar perfume"
        )

    elif q.data == "status":
        await status(
            update,
            context
        )

    elif q.data == "auto_on":
        STATE["auto"] = True

        await q.message.reply_text(
            "Modo automático ligado."
        )

    elif q.data == "auto_off":
        STATE["auto"] = False

        await q.message.reply_text(
            "Modo automático pausado."
        )


def main():
    if not TOKEN:
        raise RuntimeError(
            "TELEGRAM_BOT_TOKEN ausente"
        )

    init_db()

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
        CommandHandler("diagnostico", diagnostico)
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
        drop_pending_updates=True
    )


if __name__ == "__main__":
    main()
PY

ENV PYTHONUNBUFFERED=1

CMD ["python", "/app/bot.py"]
