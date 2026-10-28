"""文本验收门槛；不向识别器提供测试句作为提示。"""
import unicodedata


def require_model(directory):
    missing = [name for name in ['model.bin', 'config.json', 'tokenizer.json'] if not (directory / name).is_file()]
    if missing:
        raise ValueError('本地模型缺少文件：' + ', '.join(missing))


def normalize(text, converter=lambda x: x):
    text = converter(unicodedata.normalize('NFKC', text)).casefold()
    digits = str.maketrans('零一二三四五六七八九', '0123456789')
    return ''.join(c for c in text.translate(digits) if c.isalnum())


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]


def assess(expected, text, converter=lambda x: x, max_cer=.30, edge_max_cer=.5):
    expected, text = normalize(expected, converter), normalize(text, converter)
    if not expected:
        raise ValueError('期望文本不能为空')
    edge = min(10, len(expected))
    # Whole-sentence CER alone can accept an entirely missing opening or ending.
    cer = distance(expected, text) / len(expected)
    prefix = distance(expected[:edge], text[:edge]) / edge
    suffix = distance(expected[-edge:], text[-edge:]) / edge
    return {'normalized_text': text, 'cer': cer, 'prefix_cer': prefix, 'suffix_cer': suffix,
            'passed': bool(text) and cer <= max_cer and max(prefix, suffix) <= edge_max_cer}
