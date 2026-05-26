import importlib.util

from functools import lru_cache
from typing import Callable, List, Optional, Union

import lazyllm
from lazyllm.thirdparty import spacy
from lazyllm import ModuleBase, LOG
from .doc_node import DocNode, MetadataMode
from .retriever import _PostProcess


class Reranker(ModuleBase, _PostProcess):
    registered_reranker = dict()

    def __new__(cls, name: str = 'ModuleReranker', *args, **kwargs):
        assert name in cls.registered_reranker, f'Reranker: {name} is not registered, please register first.'
        item = cls.registered_reranker[name]
        if isinstance(item, type) and issubclass(item, Reranker):
            return super(Reranker, cls).__new__(item)
        else:
            return super(Reranker, cls).__new__(cls)

    def __init__(self, name: str = 'ModuleReranker', target: Optional[str] = None,
                 output_format: Optional[str] = None, join: Union[bool, str] = False, **kwargs) -> None:
        super().__init__()
        self._name = name
        self._kwargs = kwargs
        lazyllm.deprecated(bool(target), '`target` parameter of reranker')
        _PostProcess.__init__(self, output_format, join)

    def forward(self, nodes: List[DocNode], query: str = '') -> List[DocNode]:
        results = self.registered_reranker[self._name](nodes, query=query, **self._kwargs)
        LOG.debug(f'Rerank use `{self._name}` and get nodes: {results}')
        return self._post_process(results)

    @classmethod
    def register_reranker(
        cls: 'Reranker', func: Optional[Callable] = None, batch: bool = False
    ):
        def decorator(f):
            if isinstance(f, type):
                cls.registered_reranker[f.__name__] = f
                return f
            else:
                def wrapper(nodes, **kwargs):
                    if batch:
                        return f(nodes, **kwargs)
                    else:
                        results = [f(node, **kwargs) for node in nodes]
                        return [result for result in results if result]

                cls.registered_reranker[f.__name__] = wrapper
                return wrapper

        return decorator(func) if func else decorator


@lru_cache(maxsize=None)
def get_nlp_and_matchers(language):
    nlp = spacy.blank(language)

    spec = importlib.util.find_spec('spacy.matcher')
    if spec is None:
        raise ImportError(
            'Please install spacy to use spacy module. '
            'You can install it with `pip install spacy==3.7.5`'
        )
    matcher_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(matcher_module)

    required_matcher = matcher_module.PhraseMatcher(nlp.vocab)
    exclude_matcher = matcher_module.PhraseMatcher(nlp.vocab)
    return nlp, required_matcher, exclude_matcher


@Reranker.register_reranker
def KeywordFilter(node: DocNode, required_keys: Optional[List[str]] = None, exclude_keys: Optional[List[str]] = None,
                  language: str = 'en', **kwargs) -> Optional[DocNode]:
    assert required_keys or exclude_keys, 'One of required_keys or exclude_keys should be provided'
    nlp, required_matcher, exclude_matcher = get_nlp_and_matchers(language)
    if required_keys:
        required_matcher.add('RequiredKeywords', list(nlp.pipe(required_keys)))
    if exclude_keys:
        exclude_matcher.add('ExcludeKeywords', list(nlp.pipe(exclude_keys)))

    doc = nlp(node.get_text())
    if required_keys and not required_matcher(doc):
        return None
    if exclude_keys and exclude_matcher(doc):
        return None
    return node

@Reranker.register_reranker()
class ModuleReranker(Reranker):

    def __init__(self, name: str = 'ModuleReranker', model: Union[Callable, str] = None, target: Optional[str] = None,
                 output_format: Optional[str] = None, join: Union[bool, str] = False, **kwargs) -> None:
        super().__init__(name, target, output_format, join, **kwargs)
        assert model is not None, 'Reranker model must be specified as a model name or a callable.'
        if isinstance(model, str):
            self._reranker = lazyllm.TrainableModule(model)
        else:
            self._reranker = model

    def forward(self, nodes: List[DocNode], query: str = "") -> List[DocNode]:
        import sys
        print("DEBUG: ModuleReranker.forward CALLED", file=sys.stderr)
        
        if not nodes:
            return self._post_process([])

        if isinstance(query, dict):
            query_str = query.get("text", query.get("query", str(query)))
        elif hasattr(query, "get_text"):
            query_str = query.get_text()
        else:
            query_str = str(query) if query else ""

        if isinstance(query_str, DocNode):
            query_str = query_str.get_text()
        elif not isinstance(query_str, str):
            query_str = str(query_str)

        print(f"DEBUG: query_str={query_str[:50] if len(query_str) > 50 else query_str}, type={type(query_str)}", file=sys.stderr)

        docs = []
        input_is_docnode = isinstance(nodes[0], DocNode)

        print(f"DEBUG: input_is_docnode={input_is_docnode}", file=sys.stderr)

        for i, node in enumerate(nodes):
            if isinstance(node, str):
                docs.append(node)
            elif isinstance(node, dict):
                docs.append(node.get("text", str(node)))
            elif isinstance(node, DocNode):
                docs.append(node.get_text(metadata_mode=MetadataMode.EMBED))
            else:
                docs.append(str(node))

            if not isinstance(docs[-1], str):
                docs[-1] = str(docs[-1])

            if i < 3:
                print(f"DEBUG: node[{i}] type={type(node)}, doc={docs[-1][:50] if len(docs[-1]) > 50 else docs[-1]}", file=sys.stderr)

        print(f"DEBUG: docs[0] type={type(docs[0]) if docs else 'empty'}", file=sys.stderr)

        top_n = self._kwargs["topk"] if "topk" in self._kwargs else len(docs)
        sorted_indices = self._reranker(query_str, documents=docs, top_n=top_n)
        results = []

        if not input_is_docnode:
            for index, relevance_score in sorted_indices:
                node = DocNode(text=docs[index])
                node.relevance_score = relevance_score
                results.append(node)
        else:
            for index, relevance_score in sorted_indices:
                results.append(nodes[index].with_score(relevance_score))

        print(f"DEBUG: Rerank complete, results count={len(results)}", file=sys.stderr)
        return self._post_process(results)

# User-defined similarity decorator
def register_reranker(func=None, batch=False):
    return Reranker.register_reranker(func, batch)
