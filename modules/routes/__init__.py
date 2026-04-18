from .auth import auth_bp
from .config import config_bp
from .scheduler import scheduler_bp
from .service import service_bp
from .views import views_bp


def register_blueprints(app) -> None:
    app.register_blueprint(auth_bp)
    app.register_blueprint(config_bp)
    app.register_blueprint(service_bp)
    app.register_blueprint(scheduler_bp)
    app.register_blueprint(views_bp)
