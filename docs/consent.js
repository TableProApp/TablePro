// Mintlify loads every .js file here on every page. docs.json (integrations.cookies) holds all analytics
// back until localStorage has KEY = GRANTED, and reads it only on page load, so a changed answer reloads.
(() => {
    const KEY = 'tablepro:analytics-consent';
    const GRANTED = 'granted';
    const DENIED = 'denied';
    // The measurement ID in docs.json without its "G-", as GA names the stream cookie.
    const STREAM_COOKIE = '_ga_GQYNPKSK83';
    const PRIVACY_URL = 'https://tablepro.app/privacy#cookies';
    const BAR_ID = 'tablepro-consent';

    function read() {
        try {
            const value = window.localStorage.getItem(KEY);

            return value === GRANTED || value === DENIED ? value : null;
        } catch {
            return null;
        }
    }

    function write(choice) {
        try {
            window.localStorage.setItem(KEY, choice);
        } catch {
            // Storage is blocked: analytics stay off.
        }
    }

    function cookieNames() {
        return document.cookie
            .split(';')
            .map((pair) => pair.split('=')[0].trim())
            .filter((name) => name === '_ga' || name.startsWith('_ga_'));
    }

    // GA cookies sit on .tablepro.app, shared with tablepro.app, whose own stream may be there with consent.
    function clearCookies() {
        const parent = window.location.hostname.split('.').slice(-2).join('.');
        const expire = (name) => {
            document.cookie = `${name}=; Max-Age=0; path=/; domain=.${parent}`;
            document.cookie = `${name}=; Max-Age=0; path=/`;
        };

        expire(STREAM_COOKIE);

        if (!cookieNames().some((name) => name !== '_ga')) {
            expire('_ga');
        }
    }

    function choose(choice) {
        const previous = read();

        write(choice);
        document.getElementById(BAR_ID)?.remove();

        if (choice === DENIED) {
            clearCookies();
        }

        if ((choice === GRANTED) !== (previous === GRANTED)) {
            window.location.reload();
        }
    }

    // The assistant launcher sits bottom left, so the bar goes right, and above it on a phone.
    function addStyles() {
        if (document.getElementById(`${BAR_ID}-style`)) {
            return;
        }

        const style = document.createElement('style');

        style.id = `${BAR_ID}-style`;
        style.textContent = `
#${BAR_ID} { position: fixed; right: 16px; bottom: 76px; left: 16px; z-index: 60; padding: 16px; border: 1px solid #d4d4d4; border-radius: 12px; background: #fff; color: #171717; font-size: 14px; line-height: 1.5; box-shadow: 0 8px 30px rgb(0 0 0 / 0.12); }
html.dark #${BAR_ID} { border-color: #3f3f46; background: #18181b; color: #ededed; }
#${BAR_ID} p { margin: 0; }
#${BAR_ID} a { color: inherit; text-decoration: underline; }
#${BAR_ID} div { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px; }
#${BAR_ID} button { padding: 6px 12px; border: 1px solid #767676; border-radius: 8px; background: transparent; color: inherit; font: inherit; font-weight: 500; cursor: pointer; }
html.dark #${BAR_ID} button { border-color: #8f8f8f; }
#${BAR_ID} button:hover { background: rgb(127 127 127 / 0.12); }
[data-cookie-settings] { padding: 0; border: 0; background: none; color: inherit; font: inherit; font-size: 14px; white-space: nowrap; text-decoration: underline; cursor: pointer; opacity: 0.8; }
@media (min-width: 640px) { #${BAR_ID} { bottom: 16px; left: auto; width: 26rem; } }
@media print { #${BAR_ID} { display: none; } }
`;
        document.head.appendChild(style);
    }

    function showBar(focus) {
        let bar = document.getElementById(BAR_ID);

        if (!bar) {
            addStyles();

            bar = document.createElement('section');
            bar.id = BAR_ID;
            bar.setAttribute('aria-label', 'Analytics cookies');

            const text = document.createElement('p');
            const link = document.createElement('a');

            text.textContent = 'Allow Google Analytics cookies to measure visits? ';
            link.href = PRIVACY_URL;
            link.textContent = 'Privacy';
            text.appendChild(link);

            const actions = document.createElement('div');

            for (const [label, choice] of [['Allow', GRANTED], ['Decline', DENIED]]) {
                const button = document.createElement('button');

                button.type = 'button';
                button.textContent = label;
                button.addEventListener('click', () => choose(choice));
                actions.appendChild(button);
            }

            bar.append(text, actions);
            document.body.appendChild(bar);
        }

        if (focus) {
            bar.querySelector('button')?.focus();
        }
    }

    function addSettingsControl() {
        const footer = document.getElementById('footer') ?? document.querySelector('footer');

        if (!footer || footer.querySelector('[data-cookie-settings]')) {
            return;
        }

        addStyles();

        const button = document.createElement('button');

        button.type = 'button';
        button.dataset.cookieSettings = '';
        button.textContent = 'Cookie settings';
        button.addEventListener('click', () => showBar(true));
        footer.appendChild(button);
    }

    const answer = read();

    if (answer !== GRANTED) {
        clearCookies();
    }

    if (answer === null) {
        showBar(false);
    }

    // Mintlify swaps the footer with the page on navigation.
    addSettingsControl();
    window.addEventListener('mintlify:navigate', addSettingsControl);
})();
