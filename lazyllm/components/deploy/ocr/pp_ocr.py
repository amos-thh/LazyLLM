import os

os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
import lazyllm
from typing import Optional
import string
from ..base import LazyLLMDeployBase
from ...utils.file_operate import _base64_to_file

punctuation = set(string.punctuation + "，。！？；：“”‘’（）【】《》…—～、")


def is_all_punctuation(s: str) -> bool:
    return all(c in punctuation for c in s)


class _OCR(object):
    def __init__(
        self,
        model: Optional[str] = "PP-OCRv5_mobile",
        use_doc_orientation_classify: Optional[bool] = False,
        use_doc_unwarping: Optional[bool] = False,
        use_textline_orientation: Optional[bool] = False,
        **kw,
    ):
        self.model = model
        self.text_detection_model_name = model + "_det"
        self.text_recognition_model_name = model + "_rec"
        self.use_doc_orientation_classify = use_doc_orientation_classify
        self.use_doc_unwarping = use_doc_unwarping
        self.use_textline_orientation = use_textline_orientation
        self.init_flag = lazyllm.once_flag()

    def load_paddleocr(self):
        import os

        os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"

        from lazyllm.thirdparty import paddleocr

        paddleocr_kwargs = {
            "use_angle_cls": True,
            "lang": "ch",
        }

        det_model_dir = os.path.join(
            lazyllm.config["model_path"], self.text_detection_model_name
        )
        if os.path.exists(det_model_dir):
            paddleocr_kwargs["det_model_dir"] = det_model_dir
        rec_model_dir = os.path.join(
            lazyllm.config["model_path"], self.text_recognition_model_name
        )
        if os.path.exists(rec_model_dir):
            paddleocr_kwargs["rec_model_dir"] = rec_model_dir

        self.ocr = paddleocr.PaddleOCR(**paddleocr_kwargs)

    def __call__(self, input):
        lazyllm.call_once(self.init_flag, self.load_paddleocr)
        if isinstance(input, dict):
            if "inputs" in input:
                file_list = input["inputs"]
        else:
            file_list = input
        if isinstance(file_list, str):
            file_list = [file_list]

        txt = []
        for file in file_list:
            if os.path.isfile(file):
                result = self.ocr.ocr(file)
            else:
                result = self.ocr.ocr(_base64_to_file(file))
            if not result:
                continue
            for line in result:
                for item in line:
                    if isinstance(item, list) and len(item) >= 2:
                        text = item[1][0] if isinstance(item[1], tuple) else item[1]
                        t = str(text).strip()
                        if not is_all_punctuation(t) and len(t) > 0:
                            txt.append(t)
        return "\n".join(txt)

    @classmethod
    def rebuild(cls, *args, **kw):
        return cls(*args, **kw)

    def __reduce__(self):
        return _OCR.rebuild, (
            self.model,
            self.use_doc_orientation_classify,
            self.use_doc_unwarping,
            self.use_textline_orientation,
        )


class OCRDeploy(LazyLLMDeployBase):
    keys_name_handle = {
        "inputs": "inputs",
        "ocr_files": "inputs",
    }
    message_format = {"inputs": "/path/to/pdf"}
    default_headers = {"Content-Type": "application/json"}

    def __init__(
        self, launcher=None, log_path=None, trust_remote_code=True, port=None, **kw
    ):
        super().__init__(launcher=launcher)
        self._log_path = log_path
        self._trust_remote_code = trust_remote_code
        self._port = port

    def __call__(self, finetuned_model=None, base_model=None):
        if not finetuned_model:
            finetuned_model = base_model
        return lazyllm.deploy.RelayServer(
            port=self._port,
            func=_OCR(finetuned_model),
            launcher=self._launcher,
            log_path=self._log_path,
            cls="ocr",
        )()
