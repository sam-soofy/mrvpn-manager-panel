from flask import Blueprint, render_template, send_from_directory

views_bp = Blueprint("views", __name__)


@views_bp.route("/")
def index():
    return render_template("dashboard.html")


@views_bp.route("/login")
def login_page():
    return render_template("login.html")


@views_bp.route("/static/js/<path:filename>")
def serve_js(filename: str):
    return send_from_directory("static/js", filename)


@views_bp.route("/static/css/<path:filename>")
def serve_css(filename: str):
    return send_from_directory("static/css", filename)
