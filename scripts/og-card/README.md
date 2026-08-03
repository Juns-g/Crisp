# Social share cards

Regenerate docs/og-card.png and docs/og-card-zh.png after the app screenshot or tagline changes:

    chrome --headless --disable-gpu --window-size=1200,630 --screenshot=../../docs/og-card.png og-card.html
    chrome --headless --disable-gpu --window-size=1200,630 --screenshot=../../docs/og-card-zh.png og-card-zh.html

(chrome = /Applications/Google Chrome.app/Contents/MacOS/Google Chrome; run from this directory.)
