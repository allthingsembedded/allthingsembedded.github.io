
function colorize_base16(div, text) {
    let span_classes = [
        'base05', 'base08', 'base09', 'base0a', 'base0b', 'base0c', 'base0d',
        'base0e', 'base0f'
    ];

    let element = document.getElementById(div);
    for (let i = 0; i < text.length; i++) {
        let span_class = span_classes[i % span_classes.length];
        let span = document.createElement('span');
        span.textContent = text[i];
        span.setAttribute('class', span_class);
        element.appendChild(span);
    }
}
