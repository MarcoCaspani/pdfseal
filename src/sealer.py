import io, sys, os, datetime, json

# Add the 'modules' folder (next to sealer.py) to Python's import path to make sure we can import dependencies
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "modules"))

from modules import boto3
from modules.pypdf import PdfReader, PdfWriter
from modules.reportlab.pdfgen import canvas
from modules.reportlab.lib.pagesizes import A5
from base64 import b64decode


s3 = boto3.client("s3")
BUCKET = os.environ["PDF_BUCKET"]
MASTER_KEY = os.environ["MASTER_KEY"]

WATERMARK_FONT_NAME = "Helvetica-Bold"
WATERMARK_FONT_SIZE = 8
WATERMARK_OPACITY = 0.10

# Not used currently, but could be used to have the rotated watermark (45 degrees) in the center of the page
def get_watermark_BytesIO_page_45degrees_text_on_first_page(watermark_text: str) -> io.BytesIO:
    wm_buffer = io.BytesIO()
    c = canvas.Canvas(wm_buffer, pagesize=A5)
    page_width, page_height = A5
    c.setFont(WATERMARK_FONT_NAME, WATERMARK_FONT_SIZE)
    c.setFillGray(0.5, 0.3)
    c.setFillAlpha(WATERMARK_OPACITY)

    # Draw watermark rotated 45 degrees in the center of the page
    c.translate(page_width / 2, page_height / 2)
    c.rotate(45)
    c.drawCentredString(0, 0, watermark_text)
    c.save()
    wm_buffer.seek(0)
    return wm_buffer

def get_watermark_BytesIO_page_on_top_of_first_page(watermark_text: str) -> io.BytesIO:
    wm_buffer = io.BytesIO()
    c = canvas.Canvas(wm_buffer, pagesize=A5)
    page_width, page_height = A5
    c.setFont(WATERMARK_FONT_NAME, WATERMARK_FONT_SIZE)
    c.setFillGray(0.5, 0.3)
    c.setFillAlpha(WATERMARK_OPACITY)

    # Draw watermark horizontally at the top (say 30 pts from top)
    y_position = page_height - 30
    c.drawCentredString(page_width / 2, y_position, watermark_text)

    c.save()
    wm_buffer.seek(0)
    return wm_buffer

def add_watermark(input_pdf: bytes, watermark_text: str) -> bytes:
    # Create watermark PDF

    wm_buffer: io.BytesIO = get_watermark_BytesIO_page_on_top_of_first_page(watermark_text)

    watermark_reader = PdfReader(wm_buffer)
    reader = PdfReader(io.BytesIO(input_pdf))
    writer = PdfWriter()

    # Seal the first page
    first_page = reader.pages[0]
    first_page.merge_page(watermark_reader.pages[0])
    writer.add_page(first_page)

    # Add remaining pages unchanged
    for page in reader.pages[1:]:
        writer.add_page(page)

    # # Seal all pages - todo: currently disabled due to lambda timeout issues
    # for page in reader.pages:
    #     page.merge_page(watermark_reader.pages[0])
    #     writer.add_page(page)

    print(f"Master PDF pages: {len(reader.pages)}")
    print(f"Output PDF pages: {len(writer.pages)}")

    out = io.BytesIO()
    writer.write(out)
    out.seek(0)
    return out.read()

def lambda_handler(event, context) -> dict:
    # This function is triggered by API Gateway
    # A) Parse event payload
    # B) Load master PDF from S3
    # C) Add watermark with user email, order ID, and date
    # D) Upload to S3 and generate pre-signed URL
    # Return pre-signed URL in response

    # A) Parse event payload
    try:
        if "body" in event:
            body = event["body"]
            if event.get("isBase64Encoded"):  # sometimes body is base64
                body = b64decode(body).decode("utf-8")
            body = json.loads(body)
            payload = body["payload"]
        else:
            payload = event["payload"]

        # todo: validate payload contents
        order_name = payload['name']
        order_email = payload['email']
        order_id = payload['orderId']
        print(f"Sealing order {order_id} for {order_name} <{order_email}>")
    except Exception as e:
        print(f"Error parsing event payload: {e}")
        return {"statusCode": 400, "body": "Invalid payload"}

    # B) Load master PDF from S3
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=MASTER_KEY)
        master_pdf = obj["Body"].read()
        print(f"Loaded master PDF size: {len(master_pdf)} bytes") # check the loaded pdf is not an empty placeholder
    except Exception as e:
        print(f"Error loading master PDF from S3: {e}")
        return {"statusCode": 500, "body": "Error loading master PDF"}

    # C) Add watermark to the pdf
    try:
        wm_text = f"{order_name} • {order_email} • Order {order_id} • {datetime.date.today()}"
        stamped_pdf = add_watermark(master_pdf, wm_text)
    except Exception as e:
        print(f"Error adding watermark: {e}")
        return {"statusCode": 500, "body": "Error processing PDF"}

    # D) Upload to S3 and generate pre-signed URL

    # Upload stamped pdf to S3 because otherwise API Gateway limits to 5MB pdf size
    output_key = f"stamped/order-{order_id}.pdf"
    s3.put_object(Bucket=BUCKET, Key=output_key, Body=stamped_pdf)
    # Generate pre-signed URL (valid for 1 hour)
    presigned_url = s3.generate_presigned_url(
        "get_object",
        Params = {"Bucket": BUCKET, "Key": output_key},
        ExpiresIn = 3600 # generated link valid for 1 hour
    )

    return {
        "statusCode": 200,
        "body": json.dumps({"url": presigned_url}),
        "headers": {"Content-Type": "application/json"},
    }